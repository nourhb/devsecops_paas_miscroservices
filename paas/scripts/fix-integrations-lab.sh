#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"

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

cluster_url() {
  local ns="$1"
  local svc="$2"
  local port="$3"
  if ! kubectl get svc "${svc}" -n "${ns}" >/dev/null 2>&1; then
    return 1
  fi
  echo "http://${svc}.${ns}.svc.cluster.local:${port}"
}

first_svc_port() {
  local ns="$1"
  local pattern="$2"
  local name
  name="$(kubectl get svc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i "${pattern}" | head -1 || true)"
  [[ -n "${name}" ]] || return 1
  local port
  port="$(kubectl get svc -n "${ns}" "${name}" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
  [[ -n "${port}" ]] || return 1
  cluster_url "${ns}" "${name}" "${port}"
}

echo "=== 1. Cluster explorer (in-cluster API + RBAC) ==="
bash "${SCRIPT_DIR}/enable-paas-kubernetes-lab.sh"

echo "=== 2. Probe URLs (in-cluster — NodePort on VM IP often fails from paas pod) ==="

if u="$(cluster_url paas postgres 5432)"; then
  upsert_env DATABASE_URL "postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC"
  echo "DATABASE_URL -> in-cluster postgres"
fi

if u="$(first_svc_port cicd jenkins)"; then
  upsert_env JENKINS_URL "${u}"
  upsert_env JENKINS_BASE_URL "${u}"
  echo "JENKINS_URL -> ${u}"
fi

if u="$(first_svc_port harbor harbor)"; then
  upsert_env HARBOR_PROBE_URL "${u}"
  echo "HARBOR_PROBE_URL -> ${u}"
fi

if u="$(first_svc_port sonarqube sonar)"; then
  upsert_env SONAR_PROBE_URL "${u}"
  echo "SONAR_PROBE_URL -> ${u}"
fi

if u="$(first_svc_port security trivy)"; then
  upsert_env TRIVY_PROBE_URL "${u}/"
  upsert_env TRIVY_BASE_URL "${u}/"
  echo "TRIVY_PROBE_URL -> ${u}/"
fi

if u="$(first_svc_port monitoring grafana)"; then
  upsert_env GRAFANA_PROBE_URL "${u}"
  upsert_env NEXT_PUBLIC_GRAFANA_URL "${u}"
  echo "GRAFANA_PROBE_URL -> ${u}"
fi

if u="$(first_svc_port monitoring prometheus)"; then
  upsert_env PROMETHEUS_PROBE_URL "${u}"
  upsert_env NEXT_PUBLIC_PROMETHEUS_URL "${u}"
  echo "PROMETHEUS_PROBE_URL -> ${u}"
fi

if u="$(first_svc_port monitoring alertmanager)"; then
  upsert_env ALERTMANAGER_PROBE_URL "${u}"
  echo "ALERTMANAGER_PROBE_URL -> ${u}"
fi

if u="$(first_svc_port monitoring elasticsearch)"; then
  upsert_env NEXT_PUBLIC_ELASTICSEARCH_URL "${u}"
  echo "NEXT_PUBLIC_ELASTICSEARCH_URL -> ${u}"
fi

if u="$(first_svc_port monitoring kibana)"; then
  upsert_env NEXT_PUBLIC_KIBANA_URL "${u}"
  echo "NEXT_PUBLIC_KIBANA_URL -> ${u}"
fi

if u="$(first_svc_port monitoring pushgateway)"; then
  upsert_env PUSHGATEWAY_PROBE_URL "${u}"
  upsert_env NEXT_PUBLIC_PUSHGATEWAY_URL "${u}"
  echo "PUSHGATEWAY_PROBE_URL -> ${u}"
fi

if u="$(first_svc_port argocd argocd)"; then
  upsert_env ARGOCD_BASE_URL "${u/https/http}"
  echo "ARGOCD_BASE_URL -> ${u}"
fi

if u="$(first_svc_port nexus nexus)"; then
  upsert_env NEXT_PUBLIC_NEXUS_URL "${u}"
  echo "NEXT_PUBLIC_NEXUS_URL -> ${u}"
fi

if u="$(first_svc_port default artifactory)"; then
  upsert_env NEXT_PUBLIC_ARTIFACTORY_URL "${u}"
  upsert_env ARTIFACTORY_URL "${u}"
  echo "ARTIFACTORY_URL -> ${u}"
fi

if u="$(first_svc_port zap zap)"; then
  upsert_env NEXT_PUBLIC_OWASP_ZAP_URL "${u}"
  echo "NEXT_PUBLIC_OWASP_ZAP_URL -> ${u}"
fi

if u="$(first_svc_port dependency-track api)"; then
  upsert_env DEPENDENCY_TRACK_BASE_URL "${u}"
  echo "DEPENDENCY_TRACK_BASE_URL -> ${u}"
fi

upsert_env INTEGRATIONS_PROBE_HOST_REMAP ""
upsert_env INTEGRATIONS_TLS_SKIP_VERIFY "true"

echo "=== 3. Sync env + restart frontend ==="
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s

echo ""
echo "=== Services still missing in cluster (will stay Unreachable until installed) ==="
for spec in "security:trivy" "monitoring:grafana" "monitoring:elasticsearch" "monitoring:kibana" "monitoring:pushgateway" "nexus:nexus" "default:artifactory" "zap:zap"; do
  ns="${spec%%:*}"
  pat="${spec##*:}"
  if ! kubectl get svc -n "${ns}" 2>/dev/null | grep -qi "${pat}"; then
    echo "  - no Service matching '${pat}' in namespace ${ns}"
  fi
done

echo ""
echo "Refresh Platform hub. Rebuild UI after code pull: bash paas/scripts/deploy-paas-frontend-k8s.sh"
