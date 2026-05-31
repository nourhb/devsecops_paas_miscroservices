#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
JOB="paas-deploy"

# Any of these in the Pipeline script means Step 6 crane path was updated for Next 16+
CRANE_MARKERS=(
  'crane-next16-202605-nodefix'
  'crane-next16-202605-j48300-split'
  'crane-next16-202605-j48300'
  'crane-next16-202605'
)
# Pre-fix dockerless Step 6 always passed --no-lint to npx next build (breaks Next 16+)
STALE_STEP6_PATTERN='run_with_keepalive npx next build --no-lint'

if [[ -f "${ENV_FILE}" ]]; then
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
  JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_URL:-http://127.0.0.1:30090}}"
fi

jenkins_text_has_crane_fix() {
  local text="$1"
  local m
  for m in "${CRANE_MARKERS[@]}"; do
    if echo "${text}" | grep -qF "${m}"; then
      return 0
    fi
  done
  # Jenkins config.xml sometimes entity-encodes hyphens in the stored script
  if echo "${text}" | grep -qE 'crane-next16[-&#45;]+202605'; then
    return 0
  fi
  return 1
}

jenkins_job_has_stale_step6() {
  local cfg="$1"
  echo "${cfg}" | grep -qF "${STALE_STEP6_PATTERN}"
}

echo "==> Local Jenkinsfile contains crane-path fix?"
if jenkins_text_has_crane_fix "$(cat "${JENKINSFILE}")"; then
  echo "OK: repo Jenkinsfile has crane-path fix"
else
  echo "FAIL: missing crane-next16 marker in ${JENKINSFILE} — git pull origin main"
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
  echo "FAIL: Jenkins still has OLD Step 6 (npx next build --no-lint in crane path)"
  echo "Fix: bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
  exit 1
fi

if jenkins_text_has_crane_fix "${CFG}"; then
  echo "OK: Jenkins job ${JOB} is up to date ($(wc -c <<< "${CFG}") bytes config)"
  exit 0
fi

# POST may have succeeded but marker not visible in API XML — check size / Step 6a split
if echo "${CFG}" | grep -qF 'default Built-In Node' || echo "${CFG}" | grep -qF 'foreground cmd; JENKINS-48300' || echo "${CFG}" | grep -qF 'Step 6a'; then
  echo "OK: Jenkins job has j48300 Step 6 fixes (marker string not found in XML, but script content matches)"
  exit 0
fi

if echo "${CFG}" | grep -qF 'run_with_keepalive npx next build' && ! jenkins_job_has_stale_step6 "${CFG}"; then
  echo "OK: Jenkins job has current crane next build (no --no-lint); safe to build"
  exit 0
fi

echo "FAIL: Jenkins job script missing crane-next16 markers — run fix-jenkins-paas-deploy-pipeline-lab.sh"
exit 1
