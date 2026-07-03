#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

echo "=============================================="
echo " lab-fix-all-projects-deploy-now"
echo "=============================================="

bash "${SCRIPT_DIR}/lab-install-argocd-now.sh"
bash "${SCRIPT_DIR}/lab-argocd-bootstrap-all-apps.sh" || echo "WARN: Argo bootstrap partial" >&2
bash "${SCRIPT_DIR}/lab-fix-traefik-app-routing.sh" 2>/dev/null || true
COSIGN_LAB_ENFORCE_SIGNED="${COSIGN_LAB_ENFORCE_SIGNED:-false}" bash "${SCRIPT_DIR}/lab-kyverno.sh" apply 2>/dev/null || true

if [[ -f "${REPO_ROOT}/paas/scripts/lib/fix-gitops-deploy-lenient-now.sh" ]]; then
  echo "==> Ensure PaaS frontend has lenient deploy (skip if already done)"
  PAAS_SKIP_FRONTEND_REBUILD="${PAAS_SKIP_FRONTEND_REBUILD:-true}" \
    bash "${SCRIPT_DIR}/fix-gitops-deploy-lenient-now.sh" 2>/dev/null || true
fi

bash "${SCRIPT_DIR}/lab-heal-all-projects.sh"

echo ""
echo "=============================================="
echo "All projects processed."
echo "New Jenkins builds will auto-deploy via PaaS + Argo CD."
echo "Re-trigger a deploy from PaaS UI to refresh FAILED status rows."
echo "=============================================="
