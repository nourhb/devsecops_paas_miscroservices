#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"

if [[ -f "${ENV_FILE}" ]]; then
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
  JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_BASE_URL:-${JENKINS_URL}}}"
  [[ "${JENKINS_URL}" == *".svc.cluster.local"* ]] && JENKINS_URL="http://127.0.0.1:30090"
fi
JENKINS_URL="${JENKINS_URL%/}"

CRED_ID="${CREDENTIAL_ID:-github-paas}"
GH_USER="${GITHUB_USER:-}"
GH_PAT="${GITHUB_PAT:-}"

if [[ -z "${GH_USER}" || -z "${GH_PAT}" ]]; then
  echo "Set GITHUB_USER and GITHUB_PAT, then re-run."
  echo "Or create credential manually in Jenkins UI with ID: ${CRED_ID}"
  echo "PaaS/Jenkins parameter: GIT_CREDENTIALS_ID=${CRED_ID}"
  exit 0
fi

if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
  echo "ERROR: JENKINS_USERNAME and JENKINS_API_TOKEN required in ${ENV_FILE}" >&2
  exit 1
fi

echo "Create Jenkins credential '${CRED_ID}' via UI (API create varies by plugin version):"
echo "  ${JENKINS_URL}/manage/credentials/"
echo "  Kind: Username with password"
echo "  Username: ${GH_USER}"
echo "  Password: <your PAT>"
echo "  ID: ${CRED_ID}"
echo ""
echo "Then ensure paas-deploy passes GIT_CREDENTIALS_ID=${CRED_ID} (PaaS sync adds the parameter)."
