#!/usr/bin/env bash
# cosign verify from frontend pod — DOCKER_CONFIG + Harbor nginx/cluster hosts.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
IMAGE="${1:?usage: cosign-verify-from-frontend-pod-lab.sh IMAGE_REF}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }

HARBOR_USER="$(grep '^HARBOR_USERNAME=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
HARBOR_PASS="$(grep '^HARBOR_PASSWORD=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
EXTERNAL="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
CLUSTER="$(grep '^HARBOR_REGISTRY_CLUSTER=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' || true)"
NGINX="$(grep '^HARBOR_REGISTRY_NGINX_CLUSTER=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' || true)"

REFS=()
# Signatures are stored on the NodePort registry used at sign time — try external first.
REFS+=("${IMAGE}")
if [[ -n "${EXTERNAL}" && -n "${NGINX}" && "${IMAGE}" == "${EXTERNAL}/"* ]]; then
  REFS+=("${IMAGE/${EXTERNAL}/${NGINX}}")
fi
if [[ -n "${EXTERNAL}" && -n "${CLUSTER}" && "${IMAGE}" == "${EXTERNAL}/"* ]]; then
  REFS+=("${IMAGE/${EXTERNAL}/${CLUSTER}}")
fi

pod_cosign_verify() {
  local ref="$1"
  # Use DOCKER_CONFIG only (same as Security API). --registry-username flags break Harbor sig lookup in lab.
  kubectl exec -n paas deploy/frontend -- sh -ce "
    export DOCKER_CONFIG=/etc/docker
    exec cosign verify \
      --key /etc/cosign/cosign.pub \
      --allow-insecure-registry \
      '${ref}'
  "
}

for REF in "${REFS[@]}"; do
  echo "==> pod verify ${REF}"
  if pod_cosign_verify "${REF}"; then
    echo "OK: verified ${REF} from frontend pod"
    exit 0
  fi
done

echo "ERROR: cosign verify failed for all registry hosts from frontend pod" >&2
echo "Hint: bash paas/scripts/wire-harbor-docker-auth-frontend-lab.sh" >&2
exit 1
