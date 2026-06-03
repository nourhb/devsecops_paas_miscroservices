#!/usr/bin/env bash
# Poll paas-deploy until finished. Usage: BUILD_NUMBER=297 bash paas/scripts/wait-jenkins-paas-build-lab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JOB="${JOB_NAME:-paas-deploy}"
BUILD="${BUILD_NUMBER:-}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
INTERVAL="${WAIT_INTERVAL_SEC:-30}"
MAX_WAIT="${WAIT_MAX_SEC:-7200}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u
JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_LAB_LOOPBACK:-${JENKINS_URL}}}"
JENKINS_URL="${JENKINS_URL%/}"

if [[ -z "${BUILD}" ]]; then
  BUILD="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/lastBuild/api/json" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('number') or '')")"
fi
[[ -n "${BUILD}" ]] || { echo "FAIL: no build number (set BUILD_NUMBER=)" >&2; exit 1; }

echo "Waiting for ${JOB} #${BUILD} (max ${MAX_WAIT}s)…"
start=$(date +%s)
while true; do
  json="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${BUILD}/api/json")"
  result="$(printf '%s' "${json}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result') or 'RUNNING')")"
  building="$(printf '%s' "${json}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('building', True))")"
  echo "$(date -u +%H:%M:%S) #${BUILD} result=${result} building=${building}"
  if [[ "${building}" == "False" || "${building}" == "false" ]]; then
    echo "DONE: ${result}"
    [[ "${result}" == "SUCCESS" ]]
    exit $?
  fi
  now=$(date +%s)
  if (( now - start > MAX_WAIT )); then
    echo "TIMEOUT after ${MAX_WAIT}s" >&2
    exit 1
  fi
  sleep "${INTERVAL}"
done
