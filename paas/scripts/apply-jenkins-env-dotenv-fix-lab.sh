#!/usr/bin/env bash
# Push Jenkinsfile env-loader fix to Jenkins (EMAIL_PASS with spaces / no . ./.env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
MARKER="env-safe-dotenv-loader-20260601"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi
if ! grep -qF "${MARKER}" "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing ${MARKER} — git pull on this VM first" >&2
  exit 1
fi

echo "==> Jenkinsfile OK (${MARKER})"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || true

if [[ -f "${ENV_FILE}" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

echo "==> Update Jenkins paas-deploy inline pipeline"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force

echo ""
echo "Verify next build console starts with:"
echo "  [paas-jenkinsfile] marker=${MARKER}"
echo "  [env] loaded N variable(s) for build (..., EMAIL_PASS=<redacted>, ...)"
echo ""
echo "Then trigger Deploy again from PaaS for sanhome."
