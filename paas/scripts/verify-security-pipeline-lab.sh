#!/usr/bin/env bash
# End-to-end: Jenkins Steps 4–5 → Sonar/DT → PaaS Security UI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
JOB="${JOB_NAME:-paas-deploy}"
PROJECT_ID="${PROJECT_ID:-}"
AUTO_FIX="${AUTO_FIX:-0}"
FAIL=0

warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }
ok() { echo "OK: $*"; }

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u
# Lab scripts run on VM host — use loopback NodePort, not in-cluster service URL.
JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_LAB_LOOPBACK:-${JENKINS_URL}}}"
JENKINS_URL="${JENKINS_URL%/}"

if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
  echo "ERROR: JENKINS_USERNAME / JENKINS_API_TOKEN required in ${ENV_FILE}" >&2
  exit 1
fi

echo "=== 1. PaaS env + pod (security credentials) ==="
for k in SONAR_BASE_URL SONAR_TOKEN DEPENDENCY_TRACK_BASE_URL DEPENDENCY_TRACK_API_KEY JENKINS_PAAS_FAST_PIPELINE; do
  eval "v=\${${k}:-}"
  if [[ -n "${v}" && "${v}" != *your-* && "${v}" != *paste* ]]; then
    ok "${k} set in env (${#v} chars)"
  else
    fail "${k} missing or placeholder in ${ENV_FILE}"
  fi
done

if kubectl get deployment frontend -n paas >/dev/null 2>&1; then
  POD_ENV="$(kubectl exec -n paas deploy/frontend -- sh -c '
    for key in SONAR_TOKEN DEPENDENCY_TRACK_API_KEY SONAR_BASE_URL DEPENDENCY_TRACK_BASE_URL JENKINS_PAAS_FAST_PIPELINE; do
      eval "val=\$$key"
      if [ -n "$val" ]; then echo "$key=set"; else echo "$key=MISSING"; fi
    done
  ' 2>/dev/null || true)"
  if [[ -n "${POD_ENV}" ]]; then
    while IFS= read -r line; do
      if [[ "${line}" == *MISSING* ]]; then fail "pod ${line}"; else ok "pod ${line}"; fi
    done <<< "${POD_ENV}"
  else
    warn "could not read env from frontend pod"
  fi
else
  warn "paas/frontend pod not found — skip pod check"
fi

echo ""
echo "=== 2. Jenkins job must define SONAR_* / DEPENDENCY_TRACK_* parameters ==="
CFG="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null || true)"
if [[ -z "${CFG}" ]]; then
  fail "cannot fetch Jenkins job config.xml from ${JENKINS_URL} (check JENKINS_USERNAME/API_TOKEN)"
else
  for p in SONAR_HOST_URL SONAR_TOKEN DEPENDENCY_TRACK_BASE_URL DEPENDENCY_TRACK_API_KEY; do
    if echo "${CFG}" | grep -q "<name>${p}</name>"; then
      ok "job parameter ${p} defined"
    else
      fail "job parameter ${p} NOT in paas-deploy — PaaS trigger values are dropped"
      if [[ "${AUTO_FIX}" == "1" ]]; then
        echo "     AUTO_FIX: running create_jenkins_paas_deploy_job.py --force --force-full"
        set -a; source "${ENV_FILE}"; set +a
        python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
        CFG="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null || true)"
      fi
    fi
  done
fi

if echo "${CFG}" | grep -qF 'npx next build --no-lint --webpack'; then
  fail "Jenkinsfile Step 3 still has invalid --no-lint --webpack (breaks Next builds)"
  if [[ "${AUTO_FIX}" == "1" ]]; then
    bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh"
  fi
elif echo "${CFG}" | grep -qE 'crane-next16|Step 6b|foreground cmd; JENKINS-48300'; then
  ok "Jenkinsfile has crane-next16 Step 6 fix in job config"
else
  warn "could not confirm Jenkinsfile markers in config.xml"
fi

echo ""
echo "=== 3. Last Jenkins build (must SUCCESS + Steps 4–5 for Security UI data) ==="
LAST_JSON="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/lastBuild/api/json" 2>/dev/null || echo '{}')"
BUILD="$(printf '%s' "${LAST_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number') or 0)" 2>/dev/null || echo 0)"
RESULT="$(printf '%s' "${LAST_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result') or 'NONE')" 2>/dev/null || echo NONE)"

if [[ "${BUILD}" == "0" ]]; then
  fail "no Jenkins builds yet — deploy once from PaaS UI"
else
  echo "Last build: #${BUILD} result=${RESULT}"
  if [[ "${RESULT}" != "SUCCESS" ]]; then
    fail "last build #${BUILD} is ${RESULT} — Security UI stays empty until Jenkins SUCCESS"
    echo "     Step 3 failure? grep console:"
    echo "     curl -fsS -u \"\$JENKINS_USERNAME:\$JENKINS_API_TOKEN\" \"${JENKINS_URL}/job/${JOB}/${BUILD}/consoleText\" | grep -iE 'ERROR|unknown option|Step 3|Step 4'"
  else
    ok "last build SUCCESS"
  fi

  CONSOLE="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${BUILD}/consoleText" 2>/dev/null || true)"

  if echo "${CONSOLE}" | grep -q 'PAAS_STEP_SKIP step=4'; then
    fail "Step 4 skipped (fast pipeline or config)"
  elif echo "${CONSOLE}" | grep -qE 'Step 4|SCA \(Dependency-Check'; then
    ok "Step 4 ran"
  else
    fail "Step 4 never ran (pipeline failed earlier)"
  fi

  if echo "${CONSOLE}" | grep -qiE 'non configuré|SONAR not set'; then
    fail "Sonar/DT credentials missing on build #${BUILD}"
  elif echo "${CONSOLE}" | grep -qiE 'analysis submitted|sonarqube-scanner|api/v1/bom'; then
    ok "security scans submitted on build #${BUILD}"
  elif echo "${CONSOLE}" | grep -qE 'Step 5|SonarQube'; then
    warn "Step 5 ran but no clear submit line — check full console"
  else
    fail "Step 5 never ran"
  fi

  if echo "${CONSOLE}" | grep -q "unknown option '--webpack'"; then
    if echo "${CFG}" | grep -qF 'do not pass --webpack'; then
      warn "build #${BUILD} failed with old --webpack bug — job config is fixed; trigger a NEW deploy from PaaS"
    else
      fail "Step 3 --webpack bug still in Jenkins job config — run: python3 paas/scripts/create_jenkins_paas_deploy_job.py --force --force-full"
    fi
  fi
fi

echo ""
echo "=== 4. SonarQube + Dependency-Track APIs ==="
if [[ -n "${SONAR_TOKEN:-}" && -n "${SONAR_BASE_URL:-}" ]]; then
  SONAR_TOTAL="$(curl -s -u "${SONAR_TOKEN}:" \
    "${SONAR_BASE_URL%/}/api/projects/search?ps=1" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('paging',{}).get('total',0))" 2>/dev/null || echo 0)"
  if [[ "${SONAR_TOTAL}" -gt 0 ]]; then
    ok "Sonar has ${SONAR_TOTAL} project(s)"
  else
    fail "Sonar has 0 projects — no analysis uploaded yet"
  fi
  if [[ -n "${PROJECT_ID}" ]]; then
    SQ="$(curl -s -u "${SONAR_TOKEN}:" \
      "${SONAR_BASE_URL%/}/api/qualitygates/project_status?projectKey=${PROJECT_ID}" 2>/dev/null || true)"
    if echo "${SQ}" | grep -q projectStatus; then
      ok "Sonar quality gate API responds for PROJECT_ID=${PROJECT_ID}"
    else
      fail "Sonar has no projectKey=${PROJECT_ID} (Jenkins uses PROJECT_ID as sonar.projectKey)"
    fi
  fi
else
  fail "SONAR_BASE_URL / SONAR_TOKEN not set in shell — source ${ENV_FILE}"
fi

if [[ -n "${DEPENDENCY_TRACK_API_KEY:-}" && -n "${DEPENDENCY_TRACK_BASE_URL:-}" ]]; then
  if [[ -n "${PROJECT_ID}" ]]; then
    DT_COUNT="$(curl -s -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
      "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project?name=${PROJECT_ID}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)"
    if [[ "${DT_COUNT}" -gt 0 ]]; then
      ok "Dependency-Track has project named ${PROJECT_ID}"
    else
      fail "Dependency-Track has no project named ${PROJECT_ID} (Jenkins uploads SBOM with projectName=PROJECT_ID)"
    fi
  else
    warn "Set PROJECT_ID=<uuid> to check Dependency-Track project by name"
  fi
else
  fail "DEPENDENCY_TRACK_* not set in shell"
fi

echo ""
echo "=== 5. PaaS Security API (what the UI calls) ==="
if [[ -n "${PROJECT_ID}" ]] && kubectl get deployment frontend -n paas >/dev/null 2>&1; then
  # Call internal API from pod (needs auth cookie in real UI; here we use check-integrations if present)
  if kubectl exec -n paas deploy/frontend -- test -f paas/frontend/scripts/check-integrations.mjs 2>/dev/null; then
    kubectl exec -n paas deploy/frontend -- node paas/frontend/scripts/check-integrations.mjs 2>/dev/null \
      | grep -iE 'Sonar|Dependency-Track' || warn "check-integrations: no Sonar/DT lines"
  else
    warn "check-integrations.mjs not in image — rebuild frontend after git pull"
  fi
else
  warn "Set PROJECT_ID and ensure frontend pod is running to test UI backend"
fi

echo ""
echo "=== Summary ==="
if [[ "${FAIL}" -eq 0 ]]; then
  ok "Security pipeline chain looks healthy. Refresh Security tab in PaaS UI."
  echo "If UI still empty: hard-refresh browser; confirm you open Security for project ${PROJECT_ID:-<your-uuid>}."
else
  echo ""
  echo "Security UI is empty because one or more links in the chain above failed."
  echo "Typical lab fix (run on VM):"
  echo "  AUTO_FIX=1 PROJECT_ID=<uuid> bash paas/scripts/verify-security-pipeline-lab.sh"
  echo "  # then Deploy from PaaS UI (not Rebuild), wait Jenkins SUCCESS, re-run this script"
  exit 1
fi
