#!/usr/bin/env bash
# Install Argo CD when Application CRD is missing (root cause: GitOps commits never reach the cluster).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
NODE_IP="${NODE_IP:-192.168.56.129}"
MANIFEST_URL="${ARGOCD_MANIFEST_URL:-https://raw.githubusercontent.com/argoproj/argo-cd/v2.12.4/manifests/install.yaml}"

has_argocd_crd() {
  kubectl get crd applications.argoproj.io >/dev/null 2>&1
}

apply_argocd_manifest() {
  echo "==> Applying Argo CD manifest (server-side — avoids ApplicationSet annotation limit)"
  if kubectl apply -n "${ARGOCD_NS}" --server-side --force-conflicts -f "${MANIFEST_URL}" 2>&1 | tee /tmp/argocd-install.log; then
    return 0
  fi
  if grep -q 'applicationsets.argoproj.io' /tmp/argocd-install.log 2>/dev/null; then
    echo "WARN: ApplicationSet CRD failed (non-fatal for Rolling deploys) — continuing"
    curl -fsSL "${MANIFEST_URL}" | grep -v 'kind: ApplicationSet' | grep -v 'applicationsets.argoproj.io' \
      | kubectl apply -n "${ARGOCD_NS}" --server-side --force-conflicts -f - 2>/dev/null || true
  fi
}

echo "==> Argo CD CRD check"
kubectl create namespace "${ARGOCD_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
if has_argocd_crd; then
  echo "OK: argoproj.io/Application CRD present"
else
  echo "WARN: Argo CD not installed — GitOps commits to GitHub do not create pods for new projects"
  apply_argocd_manifest
fi

kubectl patch svc argocd-server -n "${ARGOCD_NS}" -p '{"spec":{"type":"NodePort"}}' 2>/dev/null || true
echo "==> Waiting for argocd-server + repo-server (up to 6 min)"
kubectl rollout status deployment/argocd-server -n "${ARGOCD_NS}" --timeout=360s 2>/dev/null || true
kubectl rollout status deployment/argocd-repo-server -n "${ARGOCD_NS}" --timeout=360s 2>/dev/null || true
kubectl get pods -n "${ARGOCD_NS}" 2>/dev/null | head -10 || true

if [[ -f "${SCRIPT_DIR}/bootstrap-argocd-lab.sh" ]]; then
  echo "==> Bootstrap ARGOCD_BASE_URL + password into PaaS env"
  bash "${SCRIPT_DIR}/bootstrap-argocd-lab.sh" || echo "WARN: bootstrap-argocd-lab failed — set ARGOCD_* manually" >&2
fi

if [[ -f "${REPO_ROOT}/paas/scripts/lab.sh" ]]; then
  echo "==> Sync PaaS frontend env to cluster"
  bash "${REPO_ROOT}/paas/scripts/lab.sh" env 2>/dev/null || true
fi

echo ""
echo "Argo CD UI (NodePort):"
kubectl get svc argocd-server -n "${ARGOCD_NS}" -o wide 2>/dev/null || true
echo ""
echo "Next: bash paas/scripts/lib/lab-argocd-bootstrap-all-apps.sh"
echo "      bash paas/scripts/lib/lab-heal-all-projects.sh"
