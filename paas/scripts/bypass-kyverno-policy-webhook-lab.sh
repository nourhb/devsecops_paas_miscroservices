#!/usr/bin/env bash
# When kyverno-svc has no endpoints, policy mutate webhooks block kubectl apply on ClusterPolicy.
# Temporarily set failurePolicy=Ignore on Kyverno *policy* webhooks (lab only).
set -euo pipefail

patch_webhooks_ignore() {
  local kind="$1"
  local names
  names="$(kubectl get "${kind}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i kyverno | grep -i policy || true)"
  if [[ -z "${names}" ]]; then
    return 0
  fi
  while IFS= read -r wh; do
    [[ -z "${wh}" ]] && continue
    local n
    n="$(kubectl get "${kind}" "${wh}" -o jsonpath='{.webhooks}' 2>/dev/null \
      | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo 0)"
    [[ "${n}" -eq 0 ]] && continue
    local patch="["
    local i
    for ((i = 0; i < n; i++)); do
      [[ "${i}" -gt 0 ]] && patch+=","
      patch+="$(printf '{"op":"replace","path":"/webhooks/%s/failurePolicy","value":"Ignore"}' "${i}")"
    done
    patch+="]"
    echo "==> ${kind}/${wh}: failurePolicy=Ignore (${n} webhook(s))"
    kubectl patch "${kind}" "${wh}" --type=json -p "${patch}" >/dev/null
  done <<< "${names}"
}

echo "==> Bypass broken Kyverno policy webhooks (kyverno-svc has no endpoints)"
patch_webhooks_ignore mutatingwebhookconfigurations
patch_webhooks_ignore validatingwebhookconfigurations
echo "OK: policy webhooks set to Ignore — kubectl apply ClusterPolicy should work now"
echo "After policies are applied, run: bash paas/scripts/recover-kyverno-lab.sh"
