#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

die() { echo "ERROR: $*" >&2; exit 1; }

upsert_env() {
  local key="$1"
  local val="$2"
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE} — copy from paas/frontend/docker-compose.env.k8s.example"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

remove_env() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || return 0
  sed -i "/^${key}=/d" "${ENV_FILE}" 2>/dev/null || true
}

echo "=== 1. Cluster explorer (in-cluster API + RBAC) ==="
bash "${SCRIPT_DIR}/enable-paas-kubernetes-lab.sh"

echo "=== 2. Probe URLs matched to this lab cluster ==="
upsert_env KUBERNETES_ENABLED "true"
upsert_env KUBE_CONFIG_PATH ""
upsert_env INTEGRATIONS_PROBE_HOST_REMAP ""
upsert_env INTEGRATIONS_TLS_SKIP_VERIFY "true"
upsert_env APPS_PUBLIC_LAB_NODE_IP "${NODE_IP}"

upsert_env DATABASE_URL "postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC"

upsert_env TRIVY_PROBE_URL "http://${NODE_IP}:30954"
upsert_env TRIVY_BASE_URL "http://${NODE_IP}:30954"

upsert_env GRAFANA_PROBE_URL "http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80"
upsert_env NEXT_PUBLIC_GRAFANA_URL "http://${NODE_IP}:32383"

upsert_env PROMETHEUS_PROBE_URL "http://${NODE_IP}:30536"
upsert_env NEXT_PUBLIC_PROMETHEUS_URL "http://${NODE_IP}:30536"

upsert_env NEXT_PUBLIC_ELASTICSEARCH_URL "http://elasticsearch-master.monitoring.svc.cluster.local:9200"

upsert_env PUSHGATEWAY_PROBE_URL "http://pushgateway-prometheus-pushgateway.monitoring.svc.cluster.local:9091"
upsert_env NEXT_PUBLIC_PUSHGATEWAY_URL "http://${NODE_IP}:31481"

upsert_env NEXT_PUBLIC_NEXUS_URL "http://nexus-nexus-repository-manager.devtools.svc.cluster.local:8081"
upsert_env NEXT_PUBLIC_ARTIFACTORY_URL "http://artifactory.devtools.svc.cluster.local:8082"
upsert_env ARTIFACTORY_URL "http://artifactory.devtools.svc.cluster.local:8082"

upsert_env NEXT_PUBLIC_OWASP_ZAP_URL "http://zap.security.svc.cluster.local:8080"

remove_env NEXT_PUBLIC_KIBANA_URL

if kubectl get svc -n monitoring 2>/dev/null | grep -qi kibana; then
  upsert_env NEXT_PUBLIC_KIBANA_URL "http://${NODE_IP}:5601"
else
  echo "Kibana: no Service in monitoring — removed NEXT_PUBLIC_KIBANA_URL (optional)"
fi

echo "=== 3. Sync env + restart frontend ==="
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo ""
echo "=== 4. Verify pod env ==="
kubectl exec -n "${PAAS_NS}" deploy/frontend -- sh -c '
  echo KUBERNETES_ENABLED=$KUBERNETES_ENABLED
  echo TRIVY_PROBE_URL=$TRIVY_PROBE_URL
  echo GRAFANA_PROBE_URL=$GRAFANA_PROBE_URL
  echo NEXT_PUBLIC_NEXUS_URL=$NEXT_PUBLIC_NEXUS_URL
' 2>/dev/null || true

echo ""
echo "=== 5. Quick probe from frontend pod ==="
kubectl exec -n "${PAAS_NS}" deploy/frontend -- wget -q -O- -T 5 http://kube-prometheus-stack-grafana.monitoring.svc.cluster.local:80/api/health 2>/dev/null | head -c 80 || echo "Grafana in-cluster: check monitoring pods"
kubectl exec -n "${PAAS_NS}" deploy/frontend -- wget -q -O- -T 5 "http://${NODE_IP}:30954/healthz" 2>/dev/null | head -c 80 || echo "Trivy NodePort: check security/trivy-service pods"

echo ""
echo "Done. Rebuild UI to remove 'null' text: bash paas/scripts/deploy-paas-frontend-k8s.sh"
echo "Then refresh Platform hub."
