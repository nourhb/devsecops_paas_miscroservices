#!/usr/bin/env bash
# Pick crane push URL: in-cluster nginx only when a curl probe pod confirms it; else NodePort.
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

echo "==> Wire cluster Harbor hosts"
bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}"

EXT="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || echo 192.168.56.129:30002)"
NGINX_PUSH="$(grep '^HARBOR_REGISTRY_PUSH=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"

echo ""
echo "==> Wait for harbor-registry 2/2 Ready"
HARBOR_NS="${HARBOR_NS:-harbor}"
for i in $(seq 1 24); do
  ready="$(kubectl get pods -n "${HARBOR_NS}" -l app=harbor,component=registry \
    -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || true)"
  if ! echo "${ready}" | grep -q false; then
    echo "OK: harbor-registry ready (${ready})"
    break
  fi
  sleep 10
done

bash "${SCRIPT_DIR}/patch-harbor-nginx-large-upload-lab.sh" 2>/dev/null || true
bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || true

echo ""
verify_out="$(bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh" 2>&1)" || true
echo "${verify_out}"

if echo "${verify_out}" | grep -q "use in-cluster push"; then
  echo "OK: keep HARBOR_REGISTRY_PUSH=${NGINX_PUSH}"
elif echo "${verify_out}" | grep -q "use HARBOR_REGISTRY for crane push"; then
  upsert "HARBOR_REGISTRY_PUSH" ""
  echo "OK: HARBOR_REGISTRY_PUSH cleared — crane uses NodePort ${EXT}"
else
  upsert "HARBOR_REGISTRY_PUSH" ""
  echo "WARN: probe unclear — cleared HARBOR_REGISTRY_PUSH; using NodePort ${EXT}"
fi

echo ""
bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh"
