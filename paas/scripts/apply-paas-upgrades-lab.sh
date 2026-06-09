#!/usr/bin/env bash
# After git pull on VM: apply Jenkins env-loader + blue-green templates + env audit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"

missing=0
for f in \
  "${SCRIPT_DIR}/apply-jenkins-env-dotenv-fix-lab.sh" \
  "${SCRIPT_DIR}/sync-gitops-bluegreen-template-lab.sh" \
  "${SCRIPT_DIR}/secure-env-files.sh" \
  "${REPO_ROOT}/paas/frontend/src/server/gitops/gitops-blue-green.ts" \
  "${REPO_ROOT}/paas/gitops/apps/simple-app/templates/deployment-bluegreen.yaml"; do
  if [[ ! -f "${f}" ]]; then
    echo "MISSING: ${f}" >&2
    missing=1
  fi
done

if [[ "${missing}" -eq 1 ]]; then
  echo "" >&2
  echo "Your VM repo is missing files that exist only on the dev machine." >&2
  echo "On Windows: commit + push devsecops_paas_miscroservices, then on VM: git pull" >&2
  exit 1
fi

if ! grep -qF 'env-safe-dotenv-loader-20260601' "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile still old (no env-safe-dotenv-loader-20260601). git pull on VM first." >&2
  exit 1
fi

echo "==> Jenkins env-loader fix"
bash "${SCRIPT_DIR}/apply-jenkins-env-dotenv-fix-lab.sh"

echo "==> Blue-green Helm templates → ~/gitops"
bash "${SCRIPT_DIR}/sync-gitops-bluegreen-template-lab.sh"

echo "==> Env file audit"
bash "${SCRIPT_DIR}/secure-env-files.sh" --fix

echo ""
echo "Next:"
echo "  bash ${SCRIPT_DIR}/push-gitops-lab.sh 'chore: blue-green helm templates'"
echo "  bash ${SCRIPT_DIR}/set-lab-env-key.sh PAAS_DEPLOYMENT_STRATEGY BlueGreen sync"
echo "  Trigger Deploy from PaaS for sanhome"
