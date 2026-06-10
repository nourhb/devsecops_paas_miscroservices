#!/usr/bin/env bash
# Force paas-deploy job to include SONAR_* and DEPENDENCY_TRACK_* (PaaS trigger values are dropped otherwise).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JOB="${JOB_NAME:-paas-deploy}"
JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a

echo "==> Refresh Jenkinsfile + full job parameters"
bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo "==> Verify parameters in config.xml"
CFG="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL%/}/job/${JOB}/config.xml")"
for p in SONAR_HOST_URL SONAR_TOKEN DEPENDENCY_TRACK_BASE_URL DEPENDENCY_TRACK_API_KEY JENKINS_PAAS_FAST_PIPELINE; do
  if echo "${CFG}" | grep -q "<name>${p}</name>"; then
    echo "OK: ${p}"
  else
    echo "FAIL: ${p} missing" >&2
    exit 1
  fi
done
FAST_DEF="$(printf '%s' "${CFG}" | python3 -c "
import re, sys
xml = sys.stdin.read()
m = re.search(
    r'<hudson\\.model\\.StringParameterDefinition>[\\s\\S]*?<name>JENKINS_PAAS_FAST_PIPELINE</name>[\\s\\S]*?<defaultValue>([^<]*)</defaultValue>',
    xml,
)
print((m.group(1) if m else '').strip())
" 2>/dev/null || true)"
if [[ "${FAST_DEF}" == "true" ]]; then
  echo "FAIL: JENKINS_PAAS_FAST_PIPELINE job default is true — re-run: python3 paas/scripts/create_jenkins_paas_deploy_job.py --force --force-full" >&2
  exit 1
fi
echo "OK: JENKINS_PAAS_FAST_PIPELINE default=${FAST_DEF:-false}"
echo "Done. Trigger a new deploy so Steps 4–5 receive credentials."
