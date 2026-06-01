#!/usr/bin/env bash
# Fix security data after a SUCCESS Jenkins build (Sonar token, Cosign verify, optional redeploy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PROJECT_NAME="${1:-dockerized-nextjs}"

cd "${REPO_ROOT}"

echo "==> 1. Regenerate Sonar token + sync Jenkins job"
bash "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh"

echo "==> 2. Jenkinsfile (yarn SBOM + cosign digest) + job sync"
bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh"

echo "==> 3. Cosign + Harbor auth on frontend"
bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh"
bash "${SCRIPT_DIR}/sign-all-deployed-paas-images-lab.sh" || true

echo "==> 4. Rebuild frontend if Harbor Trivy / cosign API still empty"
if [[ "${REBUILD_FRONTEND:-0}" == "1" ]]; then
  bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"
fi

PROJECT_ID="$(bash "${SCRIPT_DIR}/get-project-id-lab.sh" "${PROJECT_NAME}")"
echo ""
echo "==> 5. Trigger full pipeline for ${PROJECT_NAME} (${PROJECT_ID})"
export PROJECT_ID
python3 "${SCRIPT_DIR}/trigger-paas-deploy-lab.py"

echo ""
echo "Wait for Jenkins SUCCESS, then:"
echo "  PROJECT_ID=${PROJECT_ID} bash paas/scripts/verify-security-pipeline-lab.sh"
echo "  Refresh Security page for ${PROJECT_NAME}"
