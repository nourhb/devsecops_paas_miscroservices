#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
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
BUILD_ARGS=()
if [[ "${FORCE_FRONTEND_REBUILD:-false}" == "true" ]] || [[ "${NO_CACHE:-false}" == "true" ]]; then
  BUILD_ARGS+=(--no-cache)
  echo "==> Force rebuild (no Docker cache)"
fi
docker build "${BUILD_ARGS[@]}" -f "${REPO_ROOT}/paas/frontend/Dockerfile" -t "${TARGET_IMAGE}" "${REPO_ROOT}/paas"

harbor_push_image() {
  local img="$1"
  local node_ip="${NODE_IP:-192.168.56.129}"
  local harbor_port="${HARBOR_NODEPORT:-30002}"
  local harbor_user="${HARBOR_USER:-admin}"
  local harbor_pass="${HARBOR_PASS:-Harbor12345}"
  local registry="${node_ip}:${harbor_port}"
  if [[ "${img}" != "${registry}"/* ]]; then
    echo "==> Skip Harbor push (image not under ${registry})"
    return 0
  fi
  echo "==> Push to Harbor (survives local image prune)"
  if ! echo "${harbor_pass}" | docker login "${registry}" -u "${harbor_user}" --password-stdin 2>/dev/null; then
    echo "WARN: Harbor docker login failed — image only in local docker/containerd" >&2
    return 0
  fi
  local ok=0
  for attempt in 1 2 3; do
    if docker push "${img}"; then
      ok=1
      break
    fi
    if [[ "${attempt}" -lt 3 ]]; then
      echo "WARN: docker push ${img} failed (attempt ${attempt}/3) — retry in 10s" >&2
      sleep 10
    fi
  done
  if [[ "${ok}" -ne 1 ]]; then
    echo "WARN: docker push ${img} failed after 3 attempts" >&2
  fi
  docker tag "${img}" "${IMAGE_REPO}:latest"
  for attempt in 1 2 3; do
    if docker push "${IMAGE_REPO}:latest" 2>/dev/null; then
      break
    fi
    [[ "${attempt}" -lt 3 ]] || true
    sleep 5
  done
}

harbor_push_image "${TARGET_IMAGE}"

if [[ "${TARGET_IMAGE}" == docker.io/library/paas-frontend:* || "${TARGET_IMAGE}" == paas-frontend:* ]]; then
  docker tag "${TARGET_IMAGE}" "docker.io/library/paas-frontend:recovery" 2>/dev/null || true
fi

echo "==> Load image into k3s containerd on master (lab UI runs on master — worker import optional)"
if command -v docker >/dev/null 2>&1; then
  docker save "${TARGET_IMAGE}" | sudo k3s ctr -n k8s.io images import - 2>/dev/null \
    || docker save "${TARGET_IMAGE}" | sudo ctr -n k8s.io images import - 2>/dev/null || true
  if [[ "${LAB_IMPORT_IMAGE_ALL_NODES:-false}" == "true" ]]; then
    bash "${SCRIPT_DIR}/lab-k3s-import-image-nodes.sh" "${TARGET_IMAGE}" || true
  else
    echo "==> Skip worker image import (set LAB_IMPORT_IMAGE_ALL_NODES=true to push to all nodes)"
  fi
fi

if [[ -f "${SCRIPT_DIR}/lab-frontend-lab-safety.sh" ]]; then
  source "${SCRIPT_DIR}/lab-frontend-lab-safety.sh"
  stop_frontend_storm_if_needed 3
fi

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 88 ]]; then
  echo "ERROR: disk at ${DISK_PCT}% — free space before frontend rollout (run: bash paas/scripts/lab.sh disk-emergency)" >&2
  exit 1
fi

echo "==> Kyverno fail-open so deployment patch is not blocked"
bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true

echo "==> Updating deployment/frontend (Recreate + master pin + imagePullPolicy Never for local image)"
DEPLOY_IMAGE="${TARGET_IMAGE}"
if [[ "${TARGET_IMAGE}" == docker.io/library/paas-frontend:* ]]; then
  DEPLOY_IMAGE="docker.io/library/paas-frontend:recovery"
  docker save "${DEPLOY_IMAGE}" 2>/dev/null | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
fi
if [[ -f "${SCRIPT_DIR}/lab-frontend-lab-safety.sh" ]]; then
  apply_lab_frontend_safety "${DEPLOY_IMAGE}" 1
else
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=merge -p "$(cat <<PATCH
{
  "spec": {
    "replicas": 1,
    "revisionHistoryLimit": 0,
    "strategy": {"type": "Recreate"},
    "template": {
      "spec": {
        "nodeSelector": {"kubernetes.io/hostname": "master"},
        "containers": [{
          "name": "frontend",
          "image": "${DEPLOY_IMAGE}",
          "imagePullPolicy": "Never"
        }]
      }
    }
  }
}
PATCH
)"
fi
if ! kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s; then
  echo "WARN: rollout failed — applying recovery image on master" >&2
  docker save "${TARGET_IMAGE}" 2>/dev/null | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
  docker tag "${TARGET_IMAGE}" "docker.io/library/paas-frontend:recovery" 2>/dev/null || true
  bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh" || exit 1
fi
bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
echo "OK: frontend rolled out with ${TARGET_IMAGE}"
