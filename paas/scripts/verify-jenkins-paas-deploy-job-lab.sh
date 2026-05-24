#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
JOB="paas-deploy"

CRANE_FIX_MARKER='crane-next16-202605'
STALE_CRANE_STEP6='version.split('\''.'\'').map(Number);process.exit((v[0]||0)>=16'

if [[ -f "${ENV_FILE}" ]]; then
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
  JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_URL:-http://127.0.0.1:30090}}"
fi

jenkinsfile_has_crane_fix() {
  grep -qF "${CRANE_FIX_MARKER}" "$1"
}

jenkins_job_has_stale_step6() {
  local cfg="$1"
  echo "${cfg}" | grep -qF "${STALE_CRANE_STEP6}" && ! echo "${cfg}" | grep -qF "${CRANE_FIX_MARKER}"
}

echo "==> Local Jenkinsfile contains crane-path fix?"
if jenkinsfile_has_crane_fix "${JENKINSFILE}"; then
  echo "OK: repo Jenkinsfile has crane-path fix (npm ci + Next 16 flags)"
else
  echo "FAIL: missing crane fix in ${JENKINSFILE} — git pull origin main"
  exit 1
fi

echo ""
echo "==> Jenkins job config (needs JENKINS_USERNAME + JENKINS_API_TOKEN)"
if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
  echo "WARN: set credentials in ${ENV_FILE}, then re-run"
  exit 1
fi

CFG="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null || true)"

if [[ -z "${CFG}" ]]; then
  echo "FAIL: could not fetch config.xml from ${JENKINS_URL}"
  exit 1
fi

if jenkins_job_has_stale_step6 "${CFG}"; then
  echo "FAIL: Jenkins still has OLD Step 6 (npx next build --no-lint on Next 16)"
  echo "Fix: bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
  exit 1
fi

if jenkinsfile_has_crane_fix <(echo "${CFG}"); then
  echo "OK: Jenkins job ${JOB} is up to date ($(wc -c <<< "${CFG}") bytes config)"
  exit 0
fi

echo "FAIL: Jenkins missing ${CRANE_FIX_MARKER} — run fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "Fix: cd ${REPO_ROOT} && git pull origin main && bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
exit 1
