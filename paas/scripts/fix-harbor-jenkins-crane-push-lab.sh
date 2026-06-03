#!/usr/bin/env bash
# Pick crane push URL. In-cluster ONLY if the Jenkins pod (where crane runs) can reach /v2/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

upsert() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "FAIL: missing ${ENV_FILE}" >&2; exit 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

echo "==> Wire cluster Harbor hosts (cosign verify only)"
bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}"

EXT="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo 192.168.56.129:30002)"
upsert "HARBOR_FORCE_NODEPORT_PUSH" "true"
upsert "HARBOR_REGISTRY_PUSH" ""
echo "OK: HARBOR_FORCE_NODEPORT_PUSH=true, HARBOR_REGISTRY_PUSH cleared (NodePort ${EXT})"

echo ""
echo "==> Harbor disk"
bash "${SCRIPT_DIR}/free-harbor-disk-lab.sh" || true

echo ""
echo "==> Harbor health (light probe — no restart loop)"
HARBOR_RECOVER_LIGHT=1 bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || echo "WARN: Harbor probe failed"

echo ""
echo "==> Jenkins pod must reach push registry (crane runs here, not in curl probe pod)"
sleep 3
verify_out="$(WIRE_ENV=0 bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh" 2>&1)" || true
echo "${verify_out}"

upsert "HARBOR_REGISTRY_PUSH" ""
echo "OK: crane push via NodePort ${EXT} (Jenkinsfile must not fall back to HARBOR_REGISTRY_NGINX_CLUSTER)"

grep '^HARBOR_REGISTRY_PUSH=' "${ENV_FILE}" || echo "HARBOR_REGISTRY_PUSH="

echo ""
WIRE_ENV=0 bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh"
