#!/usr/bin/env bash
set -euo pipefail

delete_pods_matching() {
  local ns="$1"
  local field_selector="${2:-}"
  local extra_grep="${3:-}"
  local args=(-n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ -n "${field_selector}" ]]; then
    args=(--field-selector "${field_selector}" "${args[@]}")
  fi
  kubectl get pods "${args[@]}" 2>/dev/null | while read -r pod; do
    [[ -z "${pod}" ]] && continue
    if [[ -n "${extra_grep}" ]] && ! kubectl get pod -n "${ns}" "${pod}" -o wide 2>/dev/null | grep -qE "${extra_grep}"; then
      continue
    fi
    echo "==> delete pod/${pod} -n ${ns}"
    kubectl delete pod -n "${ns}" "${pod}" --ignore-not-found --wait=false 2>/dev/null || true
  done
}

echo "==> Remove Failed / Evicted / unknown-status pods (all namespaces)"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${ns}" == kube-* ]] && continue
  delete_pods_matching "${ns}" "status.phase=Failed" || true
  kubectl get pods -n "${ns}" 2>/dev/null | awk '/Evicted|ContainerStatusUnknown|Error|ImagePullBackOff|ErrImageNeverPull/ {print $1}' | while read -r pod; do
    [[ -z "${pod}" || "${pod}" == NAME ]] && continue
    echo "==> delete stale pod/${pod} -n ${ns}"
    kubectl delete pod -n "${ns}" "${pod}" --ignore-not-found --wait=false --force --grace-period=0 2>/dev/null || true
  done
done

echo "OK stale pod cleanup done"
