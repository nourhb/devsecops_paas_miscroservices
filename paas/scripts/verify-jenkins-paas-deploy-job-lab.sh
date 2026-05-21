#!/usr/bin/env bash
# Confirm Jenkins job paas-deploy has the latest Jenkinsfile (not stale Groovy).
# Usage: bash paas/scripts/verify-jenkins-paas-deploy-job-lab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
JOB="paas-deploy"

# Step 3 marker alone is not enough — old jobs also skip SCA. Crane block must include NEXT_MAJOR fix.
CRANE_FIX_MARKERS=(
  'fast pipeline skipped Step 3 npm — running npm ci before next build'
  'NEXT_MAJOR=\$(node -e "try{const v=require'
  'no --no-lint (removed in Next 16)'
)
# Stale crane path (build #25 failure) — must be absent
STALE_CRANE_MARKER='process.exit((v[0]||0)>=16?0:1)'

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
  JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_URL:-http://127.0.0.1:30090}}"
fi

jenkinsfile_has_crane_fix() {
  local f="$1"
  if grep -qF "${STALE_CRANE_MARKER}" "${f}"; then
    return 1
  fi
  for m in "${CRANE_FIX_MARKERS[@]}"; do
    if grep -qF "${m}" "${f}"; then
      return 0
    fi
  done
  return 1
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

if echo "${CFG}" | grep -qF "${STALE_CRANE_MARKER}"; then
  echo "FAIL: Jenkins still has OLD Step 6 script (uses --no-lint via require next/package.json)"
  echo "Fix: python3 paas/scripts/create_jenkins_paas_deploy_job.py --force"
  exit 1
fi

if jenkinsfile_has_crane_fix <(echo "${CFG}"); then
  echo "OK: Jenkins job ${JOB} is up to date ($(wc -c <<< "${CFG}") bytes config)"
  exit 0
fi

echo "FAIL: Jenkins missing crane-path fix — run create_jenkins_paas_deploy_job.py --force"
echo "Fix:"
echo "  cd ${REPO_ROOT}"
echo "  git pull origin main"
echo "  python3 paas/scripts/create_jenkins_paas_deploy_job.py --force"
echo "  bash paas/scripts/verify-jenkins-paas-deploy-job-lab.sh"
exit 1
