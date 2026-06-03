#!/usr/bin/env bash
# Crane push via NodePort unless in-cluster nginx is provably OK. Avoid restart storms.
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

echo "==> Wire cluster Harbor hosts (cosign verify only; no HARBOR_REGISTRY_PUSH)"
bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}"

EXT="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo 192.168.56.129:30002)"

echo ""
echo "==> Harbor disk (worker2 registry PVC often 89%+ → 502 on upload)"
bash "${SCRIPT_DIR}/free-harbor-disk-lab.sh" || true

echo ""
echo "==> Single Harbor recover (no nested restarts)"
bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || echo "WARN: recover returned non-zero — wait 60s and re-probe"

echo ""
echo "==> Probe push path"
sleep 5
verify_out="$(WIRE_ENV=0 bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh" 2>&1)" || true
echo "${verify_out}"

NGINX_PUSH="$(grep '^HARBOR_REGISTRY_NGINX_CLUSTER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
if echo "${verify_out}" | grep -q "use in-cluster push"; then
  upsert "HARBOR_REGISTRY_PUSH" "${NGINX_PUSH}"
  echo "OK: HARBOR_REGISTRY_PUSH=${NGINX_PUSH}"
else
  upsert "HARBOR_REGISTRY_PUSH" ""
  echo "OK: HARBOR_REGISTRY_PUSH cleared — crane uses NodePort ${EXT}"
fi

grep '^HARBOR_REGISTRY_PUSH=' "${ENV_FILE}" || echo "HARBOR_REGISTRY_PUSH="

echo ""
WIRE_ENV=0 bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh"
