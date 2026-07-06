#!/usr/bin/env bash
# Lab script to argocd fix on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }

echo "=============================================="
echo " lab-argocd-fix — GitOps 403 / Unknown status"
echo "=============================================="

if [[ -f "${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-argocd-rbac.yaml" ]]; then
  kubectl apply --validate=false -f "${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-argocd-rbac.yaml"
  ok "Argo CD RBAC for paas-frontend service account"
fi

bash "${SCRIPT_DIR}/bootstrap-argocd-lab.sh"

if kubectl auth can-i get applications.argoproj.io \
  --namespace="${ARGOCD_NS}" \
  --as="system:serviceaccount:${PAAS_NS}:paas-frontend" >/dev/null 2>&1; then
  ok "paas-frontend can get Argo CD Applications"
else
  warn "paas-frontend still cannot get applications in ${ARGOCD_NS}"
fi

bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s

sample_app="${ARGOCD_APP_PREFIX}-sanhome"
if kubectl get application "${sample_app}" -n "${ARGOCD_NS}" >/dev/null 2>&1; then
  ok "sample application ${sample_app} exists"
  kubectl get application "${sample_app}" -n "${ARGOCD_NS}" \
    -o jsonpath='health={.status.health.status} sync={.status.sync.status}{"\n"}' 2>/dev/null || true
else
  warn "application ${sample_app} not found — run: bash paas/scripts/lab.sh argocd-apps"
fi

echo "=============================================="
echo "Done. Refresh the deployment page in the PaaS UI."
echo "Rebuild frontend if GitOps chart still shows old 403 text:"
echo "  bash paas/scripts/lab.sh frontend"
echo "=============================================="
