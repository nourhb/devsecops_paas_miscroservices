#!/usr/bin/env bash
# Quick checks after sanhome Jenkins build #254 (SCA OK; Sonar may need re-run).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../frontend/docker-compose.env}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a

PID="$(bash "${SCRIPT_DIR}/get-project-id-lab.sh" sanhome)"
BUILD="${BUILD_NUMBER:-254}"

echo "==> Jenkins #${BUILD}"
curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "http://127.0.0.1:30090/job/paas-deploy/${BUILD}/api/json" | \
  python3 -c "import json,sys; j=json.load(sys.stdin); print('result=', j.get('result'))"

echo "==> Step 4/5 markers"
curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "http://127.0.0.1:30090/job/paas-deploy/${BUILD}/consoleText" | \
  grep -iE 'PAAS_STEP_OK step=4|PAAS_STEP_OK step=5|PAAS_STEP_WARN step=5|projectName=sanhome' | tail -10

echo "==> Sonar project ${PID}"
curl -sS -u "${SONAR_TOKEN}:" "${SONAR_BASE_URL%/}/api/qualitygates/project_status?projectKey=${PID}" | head -c 200 || echo "no Sonar project yet"
echo ""

echo "==> Dependency-Track project sanhome"
curl -sS -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
  "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project?name=sanhome" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else d, 'project(s)')"

echo "==> Sign deployed image (may still be :216 until GitOps catches up)"
HARBOR="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
if [[ -n "${HARBOR}" ]]; then
  cosign sign --yes --allow-insecure-registry --key "${SCRIPT_DIR}/../.lab-cosign/cosign.key" \
    "${HARBOR}/paas/sanhome:254" 2>/dev/null && echo "OK signed :254" || echo "WARN: sign :254 failed (image may not exist in Harbor yet)"
fi
