#!/usr/bin/env bash
set -euo pipefail

bulk_delete_ns() {
  local ns="$1"
  local batch round total=0
  for round in $(seq 1 50); do
    batch="$(kubectl get pods -n "${ns}" --field-selector=status.phase=Failed -o name \
      --request-timeout=45s 2>/dev/null | head -250)"
    [[ -z "${batch}" ]] && break
    echo "==> ${ns}: delete Failed pods (batch ${round}, up to 250)"
    echo "${batch}" | xargs -r kubectl delete -n "${ns}" --force --grace-period=0 --wait=false \
      --request-timeout=60s 2>/dev/null || true
    total=$((total + 250))
    sleep 2
  done
  [[ "${total}" -gt 0 ]] && echo "==> ${ns}: queued deletion of ~${total} Failed pods (background)"
}

echo "==> Remove Failed / Evicted pods (bulk per namespace — not one-by-one)"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${ns}" == kube-* ]] && continue
  bulk_delete_ns "${ns}"
done

echo "OK stale pod cleanup done (evicted pods delete in background)"
