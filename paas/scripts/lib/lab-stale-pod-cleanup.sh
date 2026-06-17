#!/usr/bin/env bash
set -euo pipefail

bulk_delete_ns() {
  local ns="$1"
  local count
  count="$(kubectl get pods -n "${ns}" --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${count}" == "0" ]] && return 0
  echo "==> ${ns}: bulk delete ${count} Failed pods"
  kubectl delete pods -n "${ns}" --field-selector=status.phase=Failed \
    --force --grace-period=0 --wait=false 2>/dev/null || true
}

echo "==> Remove Failed / Evicted pods (bulk per namespace — not one-by-one)"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${ns}" == kube-* ]] && continue
  bulk_delete_ns "${ns}"
done

echo "OK stale pod cleanup done (evicted pods delete in background)"
