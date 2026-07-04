#!/usr/bin/env bash
# Roll out the latest local paas-frontend image without rebuilding (after disk-blocked build).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
RECOVERY="docker.io/library/paas-frontend:recovery"
WANT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"

source "${SCRIPT_DIR}/lab-frontend-lab-safety.sh"

pick_source_image() {
  local tag="$1" img build_id
  if [[ -n "${tag}" ]]; then
    img="docker.io/library/paas-frontend:${tag}"
    docker image inspect "${img}" >/dev/null 2>&1 && { echo "${img}"; return 0; }
    echo "ERROR: docker image not found: ${img}" >&2
    return 1
  fi
  while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    build_id="$(docker run --rm --entrypoint cat "${img}" /app/.paas-build-id 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -n "${build_id}" && "${build_id}" == "${WANT_SHA}" ]]; then
      echo "${img}"
      return 0
    fi
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E 'paas-frontend:local-' | sort -r || true)
  img="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E 'paas-frontend:local-' | sort | tail -1 || true)"
  [[ -n "${img}" ]] && { echo "${img}"; return 0; }
  docker image inspect "${RECOVERY}" >/dev/null 2>&1 && { echo "${RECOVERY}"; return 0; }
  return 1
}

ensure_disk_headroom() {
  local disk_pct max_pct=87
  disk_pct="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if [[ -n "${disk_pct}" && "${disk_pct}" -ge "${max_pct}" ]]; then
    echo "WARN: disk at ${disk_pct}% — cleanup before rollout"
    bash "${SCRIPT_DIR}/lab-disk-emergency-free.sh" || true
  fi
}

main() {
  echo "=============================================="
  echo " lab-frontend-finish-rollout (no rebuild)"
  echo "=============================================="
  ensure_disk_headroom

  local src
  src="$(pick_source_image "${LOCAL_TAG:-}")" || {
    echo "ERROR: no paas-frontend:local-* image — rebuild first: NO_CACHE=true bash paas/scripts/lab.sh frontend" >&2
    exit 1
  }
  echo "==> Source image: ${src}"
  local src_build
  src_build="$(docker run --rm --entrypoint cat "${src}" /app/.paas-build-id 2>/dev/null | tr -d '\r\n' || true)"
  echo "==> Image build id: ${src_build:-unknown} (want git ${WANT_SHA})"

  docker tag "${src}" "${RECOVERY}"
  purge_containerd_frontend_images "${RECOVERY}"
  import_docker_image_to_k3s "${RECOVERY}" 1

  apply_lab_frontend_safety "${RECOVERY}" 1
  force_rollout_frontend_pod
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s

  local got
  got="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- cat /app/.paas-build-id 2>/dev/null | tr -d '\r\n' || true)"
  if [[ -n "${got}" && "${got}" == "${WANT_SHA}" ]]; then
    echo "OK: frontend running build ${got}"
  else
    echo "WARN: pod build id '${got:-missing}' != git ${WANT_SHA}" >&2
  fi
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
  echo "OK: Open tool links fix active — hard-refresh Integrations (Ctrl+Shift+R)"
}

main "$@"
