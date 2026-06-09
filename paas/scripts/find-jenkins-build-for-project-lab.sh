#!/usr/bin/env bash
# Find the latest Jenkins paas-deploy build that belongs to a PaaS project (shared job).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_PROBE_URL:-http://127.0.0.1:30090}"
JOB="${JOB_NAME:-paas-deploy}"
PROJECT_NAME="${1:?usage: find-jenkins-build-for-project-lab.sh <projectName> [maxBuildsBack]}"
MAX_BACK="${2:-40}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u
JENKINS_URL="${JENKINS_URL%/}"

PROJECT_ID="$(bash "${SCRIPT_DIR}/get-project-id-lab.sh" "${PROJECT_NAME}")"
LAST="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/lastBuild/api/json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number') or 0)")"
[[ "${LAST}" != "0" ]] || { echo "ERROR: no Jenkins builds" >&2; exit 1; }

echo "Searching builds #${LAST} down to $((LAST - MAX_BACK)) for project ${PROJECT_NAME} (${PROJECT_ID})"
FOUND=""
for ((b = LAST; b > LAST - MAX_BACK && b > 0; b--)); do
  CONSOLE="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${b}/consoleText" 2>/dev/null || true)"
  if [[ -z "${CONSOLE}" ]]; then
    continue
  fi
  if printf '%s' "${CONSOLE}" | grep -qF "${PROJECT_ID}" \
    || printf '%s' "${CONSOLE}" | grep -qE "projectName=${PROJECT_NAME}[^a-z0-9-]|IMAGE_NAME=.*/${PROJECT_NAME}[:@]|paas/${PROJECT_NAME}:"; then
    read -r BRESULT BBUILDING <<< "$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
      "${JENKINS_URL}/job/${JOB}/${b}/api/json" | python3 -c "import json,sys; j=json.load(sys.stdin); print(j.get('result') or 'NONE', j.get('building'))")"
    IMAGE="$(printf '%s' "${CONSOLE}" | grep -oE "PAAS_BUILD_COMPLETE result=\S+ image=\S+ project=\S+ build=\S+" | tail -1 || true)"
    STEP45="$(printf '%s' "${CONSOLE}" | grep -E 'PAAS_STEP_(OK|WARN|FAIL|SKIP) step=[45]' | tail -3 || true)"
    echo ""
    echo "=== build #${b} result=${BRESULT} building=${BBUILDING} ==="
    [[ -n "${IMAGE}" ]] && echo "${IMAGE}"
    [[ -n "${STEP45}" ]] && printf '%s\n' "${STEP45}"
    FOUND="${b}"
    if [[ "${BRESULT}" == "SUCCESS" && "${BBUILDING}" == "False" ]]; then
      echo ""
      echo "Use: BUILD_NUMBER=${b} PROJECT_ID=${PROJECT_ID} PROJECT_NAME=${PROJECT_NAME} bash paas/scripts/verify-security-pipeline-lab.sh"
      echo "     bash paas/scripts/promote-paas-image-tag-lab.sh ${PROJECT_NAME} ${b}"
      exit 0
    fi
  fi
done

if [[ -n "${FOUND}" ]]; then
  echo ""
  echo "Latest matching build #${FOUND} (may not be SUCCESS). Trigger new deploy:"
  echo "  PROJECT_ID=${PROJECT_ID} python3 paas/scripts/trigger-paas-deploy-lab.py"
  exit 0
fi

echo "ERROR: no build in last ${MAX_BACK} runs matched ${PROJECT_NAME} (${PROJECT_ID})" >&2
echo "Trigger: PROJECT_ID=${PROJECT_ID} python3 paas/scripts/trigger-paas-deploy-lab.py" >&2
exit 1
