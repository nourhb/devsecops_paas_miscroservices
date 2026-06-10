#!/usr/bin/env bash
# Heal lab web demo projects after Jenkins SUCCESS + PaaS deploy FAIL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

cd "${REPO_ROOT}"
git pull origin main 2>/dev/null || true

echo "==> Fix gitops repo (stuck rebase / detached HEAD)"
bash "${SCRIPT_DIR}/recover-gitops-lab.sh" || true

echo "==> Sync Jenkinsfile ConfigMap (new builds use fixed nginx/python crane path)"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true

if [[ "${SKIP_GITOPS_BULK_PATCH:-1}" != "1" ]]; then
  echo "==> Push Rolling + targetPort for all GitOps apps (SKIP_GITOPS_BULK_PATCH=0)"
  SKIP_FRONTEND_REDEPLOY=1 bash "${SCRIPT_DIR}/fix-lab-rolling-deploy-now.sh" || {
    echo "WARN: fix-lab-rolling-deploy-now had errors — continuing with per-project heal"
  }
else
  echo "==> SKIP_GITOPS_BULK_PATCH=1 — per-project heal only (fast)"
fi

heal() {
  local project="$1"
  local build="$2"
  local port="${3:-}"
  if [[ -n "${port}" ]]; then
    bash "${SCRIPT_DIR}/heal-project-deploy-lab.sh" "${project}" "${build}" "${port}"
  else
    bash "${SCRIPT_DIR}/heal-project-deploy-lab.sh" "${project}" "${build}"
  fi
}

heal "${HEAL_DEMO_ANGULAR_PROJECT:-demo-angular-app}" "${HEAL_DEMO_ANGULAR_BUILD:-389}" 80
heal "${HEAL_PYTHON_PROJECT:-docker-demo-with-simple-python-app}" "${HEAL_PYTHON_BUILD:-387}" 8000
heal "${HEAL_ANGULAR_PROJECT:-angular-docker}" "${HEAL_ANGULAR_BUILD:-388}" 80

echo ""
echo "Done. Open in browser:"
echo "  http://demo-angular-app.192.168.56.129.nip.io:30659/"
echo "  http://docker-demo-with-simple-python-app.192.168.56.129.nip.io:30659/"
echo "  http://angular-docker.192.168.56.129.nip.io:30659/"
