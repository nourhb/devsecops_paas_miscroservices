#!/usr/bin/env bash
# Lab script to ui fix on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }

echo "=============================================="
echo " lab-ui-fix — Argo CD + Harbor UI + frontend rebuild"
echo "=============================================="
echo "Fixes GitOps 403, Docker/Harbor registry page, hidden Create Project sections."
echo "Requires a successful frontend image build (~3 min)."
echo ""

export SKIP_HARBOR_HEAL="${SKIP_HARBOR_HEAL:-1}"
export KUBERNETES_ENABLED="${KUBERNETES_ENABLED:-true}"

ENV_FILE="${REPO_ROOT}/paas/frontend/docker-compose.env"
patch_env_key() {
  local key="$1" value="$2"
  [[ -f "${ENV_FILE}" ]] || touch "${ENV_FILE}"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}
patch_env_key "KUBERNETES_ENABLED" "true"
ok "KUBERNETES_ENABLED=true (Argo CD uses Kubernetes API — no HTTP 403 in UI)"

echo ""
echo "==> 1/6 Argo CD RBAC + env"
bash "${SCRIPT_DIR}/lab-argocd-fix.sh" || warn "argocd-fix had warnings"

echo ""
echo "==> 2/6 Patch browser Open tool URLs (NEXT_PUBLIC_* — never .svc)"
bash "${SCRIPT_DIR}/lab-patch-browser-urls.sh" || warn "lab-patch-browser-urls had warnings"

echo ""
echo "==> 3/6 Wire integration NodePorts (Grafana, Prometheus, Harbor, …)"
if bash "${SCRIPT_DIR}/bootstrap-integrations-lab.sh"; then
  ok "integrations-bootstrap complete"
else
  warn "integrations-bootstrap had warnings"
fi
bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || warn "env sync to k8s failed"

echo ""
echo "==> 4/6 Register Argo CD Applications (paas-* from gitops/apps)"
if bash "${SCRIPT_DIR}/lab-argocd-bootstrap-all-apps.sh"; then
  ok "Argo CD applications bootstrapped"
else
  warn "argocd-apps incomplete"
fi

echo ""
echo "==> 5/6 Rebuild PaaS frontend image (loads UI fixes from git)"
export NO_CACHE="${NO_CACHE:-true}"
export FORCE_FRONTEND_REBUILD="${FORCE_FRONTEND_REBUILD:-true}"
if bash "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh"; then
  ok "frontend image rebuilt and rolled out"
else
  echo "FAIL: frontend build failed — paste the TypeScript/Docker error above" >&2
  exit 1
fi

echo ""
echo "==> 6/6 Verify deployment (build id must match git HEAD)"
WANT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
IMAGE="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
GOT_SHA="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- cat /app/.paas-build-id 2>/dev/null | tr -d '\r\n' || true)"
ok "deployment image: ${IMAGE:-unknown}"
if [[ -n "${GOT_SHA}" && "${GOT_SHA}" == "${WANT_SHA}" ]]; then
  ok "running frontend build ${GOT_SHA} (matches git HEAD)"
else
  warn "running build id '${GOT_SHA:-missing}' != git ${WANT_SHA} — browser may still show OLD UI"
  warn "force: kubectl delete pod -n ${PAAS_NS} -l app=frontend --force --grace-period=0"
  warn "then:  NO_CACHE=true bash paas/scripts/lab.sh frontend"
fi
if kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv KUBERNETES_ENABLED 2>/dev/null | grep -q true; then
  ok "pod KUBERNETES_ENABLED=true"
else
  warn "KUBERNETES_ENABLED not true in pod — run: bash paas/scripts/lab.sh env"
fi

echo ""
echo "=============================================="
echo "Done. Hard-refresh the browser (Ctrl+Shift+R):"
echo "  • GitOps — K8s API status (not 'Configure ARGOCD_*')"
echo "  • Docker page — Harbor registry label"
echo "  • Integrations — Open tool links use NodePort URLs (not .svc.cluster.local)"
echo "=============================================="
