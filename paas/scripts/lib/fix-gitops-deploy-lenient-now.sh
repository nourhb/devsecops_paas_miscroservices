#!/usr/bin/env bash
# Lab helper script for fix gitops deploy lenient now
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  echo "WARN: Argo CD Application CRD missing — run: bash paas/scripts/lib/lab-install-argocd-now.sh"
  echo "      (PaaS can still create workloads via direct-apply fallback after frontend rebuild)"
fi

echo "==> Ensure PAAS_STRICT_INTEGRATIONS=false on frontend deployment"
kubectl set env deployment/frontend -n "${PAAS_NS}" PAAS_STRICT_INTEGRATIONS=false --containers=frontend 2>/dev/null || true

if [[ "${PAAS_SKIP_FRONTEND_REBUILD:-false}" == "true" ]]; then
  echo "==> Skip frontend rebuild (PAAS_SKIP_FRONTEND_REBUILD=true)"
else
  echo "==> Rebuild and rollout frontend (lenient GitOps + direct workload apply + K8s REST secret fallback)"
  FORCE_FRONTEND_REBUILD=true bash "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh"
fi

echo "==> Smoke-check: lenient gitops string in running pod"
POD="$(kubectl get pods -n "${PAAS_NS}" -o name 2>/dev/null | grep frontend | head -1 | sed 's|pod/||' || true)"
if [[ -n "${POD}" ]]; then
  if kubectl exec -n "${PAAS_NS}" "${POD}" -- sh -c 'grep -rq "continuing deploy verification" /app 2>/dev/null'; then
    echo "OK: lenient GitOps deploy code is present in the frontend image"
  else
    echo "WARN: could not grep lenient string — image may still be stale; check rollout" >&2
  fi
  echo "==> PAAS_STRICT_INTEGRATIONS in pod:"
  kubectl exec -n "${PAAS_NS}" "${POD}" -- sh -c 'printenv PAAS_STRICT_INTEGRATIONS || echo "(unset)"' 2>/dev/null || true
fi

echo ""
echo "Next: open PaaS → warda-youssef → Deployment → Re-deploy (or promote build #78)."
echo "Deploy log should show:"
echo "  [gitops] WARN: ... continuing deploy verification"
echo "  [deploy] waiting for workload ..."
echo "  PAAS_DEPLOY_VERIFY step=workload_ready ..."
