#!/usr/bin/env bash
# Jenkins #330: why Sonar/DT APIs empty while Step 4/5 markers OK?
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_PROBE_URL:-http://127.0.0.1:30090}"
JOB="${JOB_NAME:-paas-deploy}"
BUILD="${BUILD_NUMBER:-330}"
PROJECT_NAME="${PROJECT_NAME:-sanhome}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u
JENKINS_URL="${JENKINS_URL%/}"

echo "=== Jenkins #${BUILD} security excerpts ==="
CONSOLE="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/${BUILD}/consoleText" 2>/dev/null || true)"
printf '%s\n' "${CONSOLE}" | grep -iE 'PAAS_STEP_(OK|WARN|FAIL|SKIP) step=[45]|\[sca\]|\[sonar\]|projectKey=|Dependency-Track|bom\.json|Not authorized|ANALYSIS SUCCESSFUL|EXECUTION SUCCESS|Insufficient|upload failed' | tail -40

echo ""
echo "=== sonar-scanner.log artifact (tail) ==="
curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/${BUILD}/artifact/paas-artifacts/sonar-scanner.log" 2>/dev/null | tail -30 \
  || echo "(no sonar-scanner.log artifact)"

echo ""
echo "=== Sonar API ==="
for SK in "${PROJECT_NAME}" "$(bash "${SCRIPT_DIR}/get-project-id-lab.sh" "${PROJECT_NAME}" 2>/dev/null || true)"; do
  [[ -z "${SK}" ]] && continue
  echo "--- projectKey=${SK} ---"
  curl -sS -m 15 -u "${SONAR_TOKEN}:" \
    "${SONAR_BASE_URL%/}/api/qualitygates/project_status?projectKey=${SK}" | head -c 400
  echo ""
done
echo "--- projects/search ---"
curl -sS -m 15 -u "${SONAR_TOKEN}:" "${SONAR_BASE_URL%/}/api/projects/search?ps=10" | head -c 500
echo ""

echo ""
echo "=== Dependency-Track API ==="
DT_CODE="$(curl -sS -m 15 -o /tmp/dt-sanhome.json -w '%{http_code}' \
  -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
  "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project?name=${PROJECT_NAME}" 2>/dev/null || echo 000)"
echo "HTTP ${DT_CODE} GET /api/v1/project?name=${PROJECT_NAME}"
head -c 500 /tmp/dt-sanhome.json 2>/dev/null || true
echo ""

echo ""
echo "=== Cluster image (expect :${BUILD}) ==="
kubectl get deploy -n "${PROJECT_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true
grep -E '^(blue|green|image):|tag:' "${HOME}/gitops/apps/${PROJECT_NAME}/values.yaml" 2>/dev/null | head -20 || true
