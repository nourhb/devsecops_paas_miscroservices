#!/usr/bin/env bash
# Re-sync all paas-* Argo CD apps via kubectl (no argocd CLI login required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
argo_load_lab_env "${ROOT}"

ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
WAIT_SEC="${1:-120}"

echo "==> Sync ${ARGOCD_APP_PREFIX}-* via kubectl Application CR"
count=0
while IFS= read -r app; do
  [[ -z "${app}" ]] && continue
  echo "--- ${app}"
  argo_sync_app_lab "${app}" || echo "WARN: sync trigger failed for ${app}"
  argo_wait_app_lab "${app}" "${WAIT_SEC}" || true
  count=$((count + 1))
done < <(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep "^${ARGOCD_APP_PREFIX}-" || true)

echo "==> Done (${count} app(s))"
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName' 2>/dev/null | grep -vE '^NS|^paas' || true
