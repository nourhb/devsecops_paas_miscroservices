#!/usr/bin/env bash
# Fix ComparisonError: simple-app.fullname in templates but chart _helpers.tpl defines {chart}.fullname
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"

bash "${SCRIPT_DIR}/sync-gitops-bluegreen-template-lab.sh"

echo "==> helm template smoke test (sanhome)"
helm template paas-sanhome "${GITOPS}/apps/sanhome" -f "${GITOPS}/apps/sanhome/values.yaml" \
  | grep -E '^kind:|^  name:' | head -20

bash "${SCRIPT_DIR}/push-gitops-lab.sh" "fix(gitops): per-chart helper names in blue-green templates"

echo ""
echo "==> Argo sync paas-sanhome"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
kubectl patch application paas-sanhome -n argocd --type json \
  -p='[{"op":"remove","path":"/operation"}]' 2>/dev/null || true
kubectl annotate application paas-sanhome -n argocd argocd.argoproj.io/refresh=hard --overwrite
argo_sync_app_lab paas-sanhome
argo_wait_app_lab paas-sanhome 180 || true
kubectl get deploy -n sanhome
