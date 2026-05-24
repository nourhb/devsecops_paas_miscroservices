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
  [[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}"
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

echo "=== 1. Cluster API + RBAC ==="
bash "${SCRIPT_DIR}/enable-paas-kubernetes-lab.sh"

echo "=== 2. Env: NodePort probes (from PaaS pod) + drop optional demo URLs ==="
upsert_env KUBERNETES_ENABLED "true"
upsert_env KUBE_CONFIG_PATH ""
upsert_env INTEGRATIONS_PROBE_HOST_REMAP ""
upsert_env INTEGRATIONS_TLS_SKIP_VERIFY "true"
upsert_env APPS_PUBLIC_LAB_NODE_IP "${NODE_IP}"

upsert_env TRIVY_PROBE_URL "http://harbor-trivy.harbor.svc.cluster.local:8080"
upsert_env TRIVY_BASE_URL "http://${NODE_IP}:30954"

upsert_env GRAFANA_PROBE_URL "http://${NODE_IP}:32383"
upsert_env NEXT_PUBLIC_GRAFANA_URL "http://${NODE_IP}:32383"

upsert_env NEXT_PUBLIC_ELASTICSEARCH_URL "http://elasticsearch-master.monitoring.svc.cluster.local:9200"
upsert_env PUSHGATEWAY_PROBE_URL "http://${NODE_IP}:31481"
upsert_env NEXT_PUBLIC_PUSHGATEWAY_URL "http://${NODE_IP}:31481"

remove_env NEXT_PUBLIC_NEXUS_URL
remove_env NEXT_PUBLIC_ARTIFACTORY_URL
remove_env ARTIFACTORY_URL
remove_env NEXT_PUBLIC_OWASP_ZAP_URL
remove_env NEXT_PUBLIC_KIBANA_URL
remove_env NEXT_PUBLIC_HAPROXY_STATS_URL
remove_env NEXT_PUBLIC_EDGE_IOT_URL

if kubectl get ns devtools >/dev/null 2>&1; then
  echo "WARN: devtools namespace still exists — set Nexus/Artifactory URLs manually if needed"
else
  echo "Removed Nexus/Artifactory/ZAP URLs (devtools namespace gone)"
fi

echo "=== 2b. Optional integrations (Prometheus, Vault, Tekton, …) ==="
ENV_FILE="${ENV_FILE}" NODE_IP="${NODE_IP}" bash "${SCRIPT_DIR}/wire-optional-integrations-lab.sh" || true

echo "=== 3. Sync + restart frontend ==="
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo ""
bash "${SCRIPT_DIR}/diagnose-integration-pods-lab.sh" || true

echo ""
echo "Rebuild UI if probe code changed: bash paas/scripts/deploy-paas-frontend-k8s.sh"
