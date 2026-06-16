#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
TAG="${TAG:-local-$(date +%Y%m%d%H%M%S)}"
DEFAULT_REPO="${DEFAULT_REPO:-192.168.56.129:30002/paas/frontend}"

CURRENT_IMAGE="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ -z "${CURRENT_IMAGE}" ]]; then
  echo "ERROR: deployment/frontend not found in namespace ${PAAS_NS}" >&2
  exit 1
fi

resolve_image_repo() {
  local current="$1"
  if [[ -n "${IMAGE:-}" ]]; then
    printf '%s\n' "${IMAGE%:*}"
    return
  fi
  # Valid refs look like host:port/path/name:tag — keep host:port/path/name.
  if [[ "${current}" == */* ]]; then
    printf '%s\n' "${current%:*}"
    return
  fi
  printf '%s\n' "${DEFAULT_REPO}"
}

IMAGE_REPO="$(resolve_image_repo "${CURRENT_IMAGE}")"
TARGET_IMAGE="${IMAGE_REPO}:${TAG}"

echo "==> Current deployment image: ${CURRENT_IMAGE}"
echo "==> Building ${TARGET_IMAGE} from ${REPO_ROOT}/paas"
docker build -f "${REPO_ROOT}/paas/frontend/Dockerfile" -t "${TARGET_IMAGE}" "${REPO_ROOT}/paas"

echo "==> Load image into k3s containerd (lab)"
if command -v k3s >/dev/null 2>&1; then
  docker save "${TARGET_IMAGE}" | sudo k3s ctr images import -
else
  echo "WARN: k3s not found — skipping ctr import"
fi

echo "==> Ensure Kyverno admission webhook is up (best-effort)"
if kubectl get deploy -n kyverno kyverno-admission-controller >/dev/null 2>&1; then
  kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=120s 2>/dev/null || \
    kubectl rollout restart deployment/kyverno-admission-controller -n kyverno 2>/dev/null || true
  kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=180s 2>/dev/null || true
fi

echo "==> Updating deployment/frontend"
kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
spec:
  template:
    spec:
      containers:
      - name: frontend
        image: ${TARGET_IMAGE}
        imagePullPolicy: IfNotPresent
PATCH
)"
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
echo "OK: frontend rolled out with ${TARGET_IMAGE}"
