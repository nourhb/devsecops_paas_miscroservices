#!/usr/bin/env bash
set -euo pipefail

collect_protected_images() {
  kubectl get deploy,sts,ds,jobs,cronjobs -A -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
    | sed '/^$/d' | sort -u
}

image_in_containerd() {
  local ref="$1"
  local base="${ref%%@*}"
  sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -qF "${base}" || \
    sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -qF "${ref##*/}"
}

disk_use_pct() {
  df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

should_skip_image_pull() {
  if [[ "${PAAS_SKIP_IMAGE_PULL:-}" == "1" ]]; then
    return 0
  fi
  local pct
  pct="$(disk_use_pct)"
  [[ -n "${pct}" && "${pct}" -ge 85 ]]
}

ensure_protected_images_local() {
  local still_missing=0
  if should_skip_image_pull; then
    echo "SKIP: no registry/docker pulls (disk $(disk_use_pct)% or PAAS_SKIP_IMAGE_PULL=1)"
    return 0
  fi
  while IFS= read -r img; do
    [[ -z "${img}" ]] && continue
    if image_in_containerd "${img}"; then
      echo "OK image present: ${img}"
      continue
    fi
    echo "WARN missing in containerd: ${img}"
    restored=0
    if command -v docker >/dev/null 2>&1 && docker image inspect "${img}" >/dev/null 2>&1; then
      echo "==> Re-import ${img} from local docker into k3s"
      docker save "${img}" | sudo k3s ctr -n k8s.io images import - >/dev/null
      restored=1
    elif command -v docker >/dev/null 2>&1 && docker pull "${img}" 2>/dev/null; then
      echo "==> Pulled ${img} from registry into k3s"
      docker save "${img}" | sudo k3s ctr -n k8s.io images import - >/dev/null
      restored=1
    fi
    if [[ "${restored}" -eq 1 ]] && image_in_containerd "${img}"; then
      echo "OK restored: ${img}"
      continue
    fi
    still_missing=$((still_missing + 1))
    echo "ERROR: cannot restore ${img} — rebuild or push to registry" >&2
  done < <(collect_protected_images)
  return "${still_missing}"
}

safe_docker_prune() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  echo "==> Docker prune dangling only (never prune -af — breaks deployment image tags)"
  docker image prune -f 2>/dev/null || true
}

safe_crictl_prune() {
  echo "==> Ensure workload images exist before containerd prune"
  ensure_protected_images_local || true
  if command -v k3s >/dev/null 2>&1; then
    echo "==> k3s crictl rmi --prune (unused images only)"
    sudo k3s crictl rmi --prune 2>/dev/null || true
  elif command -v crictl >/dev/null 2>&1; then
    sudo crictl rmi --prune 2>/dev/null || true
  fi
}

case "${1:-prune}" in
  protected) collect_protected_images ;;
  ensure) ensure_protected_images_local ;;
  prune)
    safe_docker_prune
    safe_crictl_prune
    ;;
  *)
    echo "usage: lab-safe-image-prune.sh [protected|ensure|prune]" >&2
    exit 1
    ;;
esac
