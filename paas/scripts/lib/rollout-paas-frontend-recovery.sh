#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
LOCAL_TAG="${LOCAL_TAG:-}"
RECOVERY="docker.io/library/paas-frontend:recovery"

# shellcheck source=lab-frontend-lab-safety.sh
source "${SCRIPT_DIR}/lab-frontend-lab-safety.sh"

if [[ -n "${LOCAL_TAG}" ]]; then
  SRC="docker.io/library/paas-frontend:${LOCAL_TAG}"
elif docker image inspect "${RECOVERY}" >/dev/null 2>&1; then
  SRC="${RECOVERY}"
else
  SRC="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E 'paas-frontend:local-' | sort | tail -1 || true)"
fi

[[ -n "${SRC}" ]] || {
  echo "ERROR: no local paas-frontend image — set LOCAL_TAG=20260620192837 or rebuild" >&2
  exit 1
}

echo "==> Source image: ${SRC}"
docker tag "${SRC}" "${RECOVERY}"
import_docker_image_to_k3s "${RECOVERY}" || true

CURRENT="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ "${CURRENT}" != "${RECOVERY}" ]]; then
  echo "==> Reset frontend image (was: ${CURRENT})"
  kubectl set image deployment/frontend -n "${PAAS_NS}" "frontend=${RECOVERY}" --request-timeout=60s
fi

apply_lab_frontend_safety "${RECOVERY}" 1
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
echo "OK: frontend running ${RECOVERY} (from ${SRC})"
