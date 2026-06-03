#!/usr/bin/env bash
# End-to-end: Jenkins Steps 4–5 → Sonar/DT → PaaS Security UI.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
JOB="${JOB_NAME:-paas-deploy}"
PROJECT_ID="${PROJECT_ID:-}"
# Optional: verify a specific Jenkins build (e.g. BUILD_NUMBER=254) instead of lastBuild
BUILD_NUMBER="${BUILD_NUMBER:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
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
  MISSING_PARAMS="$(printf '%s' "${CFG}" | python3 -c "
import sys
cfg = sys.stdin.read()
required = ['SONAR_HOST_URL', 'SONAR_TOKEN', 'DEPENDENCY_TRACK_BASE_URL', 'DEPENDENCY_TRACK_API_KEY']
missing = [p for p in required if f'<name>{p}</name>' not in cfg]
print(','.join(missing))
" 2>/dev/null || echo "parse-error")"
  for p in SONAR_HOST_URL SONAR_TOKEN DEPENDENCY_TRACK_BASE_URL DEPENDENCY_TRACK_API_KEY; do
    if [[ ",${MISSING_PARAMS}," != *",${p},"* ]]; then
      ok "job parameter ${p} defined"
    else
      fail "job parameter ${p} NOT in paas-deploy — PaaS trigger values are dropped"
    fi
  done
  if [[ -n "${MISSING_PARAMS}" && "${MISSING_PARAMS}" != "parse-error" && "${AUTO_FIX}" == "1" && "${JENKINS_PARAMS_FIXED:-0}" != "1" ]]; then
    echo "     AUTO_FIX: fix-jenkins-paas-deploy-pipeline-lab.sh + create_jenkins --force-full"
    JENKINS_PARAMS_FIXED=1
    set -a; source "${ENV_FILE}"; set +a
    bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh" || true
    python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
    CFG="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null || true)"
  fi
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

if [[ -n "${PROJECT_ID}" && -z "${PROJECT_NAME}" ]] && kubectl get deployment postgres -n paas >/dev/null 2>&1; then
  PROJECT_NAME="$(kubectl exec -n paas deploy/postgres -- psql -U postgres -d paas -tAc \
    "SELECT \"projectName\" FROM \"Project\" WHERE id = '${PROJECT_ID}' LIMIT 1;" 2>/dev/null | tr -d ' \r\n' || true)"
fi

echo ""
echo "=== 3. Jenkins build (must SUCCESS + Steps 4–5 for Security UI data) ==="
if [[ -n "${BUILD_NUMBER}" ]]; then
  BUILD="${BUILD_NUMBER}"
  LAST_JSON="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${BUILD}/api/json" 2>/dev/null || echo '{}')"
  echo "Checking build #${BUILD} (BUILD_NUMBER set)"
else
  LAST_JSON="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/lastBuild/api/json" 2>/dev/null || echo '{}')"
  BUILD="$(printf '%s' "${LAST_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('number') or 0)" 2>/dev/null || echo 0)"
  echo "Last build: #${BUILD} (set BUILD_NUMBER=<n> to verify a specific SUCCESS build)"
fi
RESULT="$(printf '%s' "${LAST_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('result') or 'NONE')" 2>/dev/null || echo NONE)"

if [[ "${BUILD}" == "0" || -z "${BUILD}" ]]; then
  fail "no Jenkins builds yet — deploy once from PaaS UI"
else
  echo "Build #${BUILD} result=${RESULT}"
  if [[ "${RESULT}" != "SUCCESS" ]]; then
    fail "build #${BUILD} is ${RESULT} — Security UI stays empty until Jenkins SUCCESS for this project"
    if [[ -z "${BUILD_NUMBER}" ]]; then
      echo "     Tip: if an older build succeeded, re-run with BUILD_NUMBER=<n> PROJECT_ID=<uuid>"
    fi
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
  fi
  if echo "${CONSOLE}" | grep -qE 'PAAS_STEP_OK step=5|analysis submitted for projectKey|ANALYSIS SUCCESSFUL'; then
    ok "Step 5 (Sonar) submitted on build #${BUILD}"
  elif echo "${CONSOLE}" | grep -q 'PAAS_STEP_SKIP step=5'; then
    fail "Step 5 skipped on build #${BUILD}"
  elif echo "${CONSOLE}" | grep -qE 'Step 5|SonarQube'; then
    if echo "${CONSOLE}" | grep -qiE 'paasStepWarn\(5|scanner exit|Not authorized'; then
      fail "Step 5 ran but Sonar failed — check SONAR_TOKEN (run: bash paas/scripts/regenerate-sonar-token-lab.sh)"
    else
      warn "Step 5 ran but no PAAS_STEP_OK — check Jenkins console for Sonar"
    fi
  else
    fail "Step 5 never ran on build #${BUILD}"
  fi
  if echo "${CONSOLE}" | grep -qE 'api/v1/bom|Dependency-Track upload|PAAS_STEP_OK step=4'; then
    ok "Step 4 (SBOM → Dependency-Track) on build #${BUILD}"
  elif echo "${CONSOLE}" | grep -qiE 'DEPENDENCY_TRACK.*not set|Dependency-Track non configuré'; then
    fail "Step 4: DEPENDENCY_TRACK_* missing on Jenkins job — run: bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
  elif echo "${CONSOLE}" | grep -q 'PAAS_STEP_SKIP step=4'; then
    fail "Step 4 skipped (fast pipeline)"
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
    SONAR_OK=0
    for SK in "${PROJECT_NAME:-}" "${PROJECT_ID}"; do
      [[ -z "${SK}" ]] && continue
      SQ="$(curl -s -u "${SONAR_TOKEN}:" \
        "${SONAR_BASE_URL%/}/api/qualitygates/project_status?projectKey=${SK}" 2>/dev/null || true)"
      if echo "${SQ}" | grep -q projectStatus; then
        ok "Sonar quality gate API responds for projectKey=${SK}"
        SONAR_OK=1
        break
      fi
    done
    if [[ "${SONAR_OK}" -eq 0 ]]; then
      fail "Sonar has no project for keys ${PROJECT_NAME:-<name>}/${PROJECT_ID} (Jenkins uses image slug e.g. sanhome)"
    fi
  fi
else
  fail "SONAR_BASE_URL / SONAR_TOKEN not set in shell — source ${ENV_FILE}"
fi

if [[ -n "${DEPENDENCY_TRACK_API_KEY:-}" && -n "${DEPENDENCY_TRACK_BASE_URL:-}" ]]; then
  if [[ -n "${PROJECT_ID}" ]]; then
    DT_LOOKUP="${PROJECT_NAME:-${PROJECT_ID}}"
    DT_COUNT="$(curl -s -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
      "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project?name=${DT_LOOKUP}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)"
    if [[ "${DT_COUNT}" -gt 0 ]]; then
      ok "Dependency-Track has project named ${DT_LOOKUP}"
    else
      fail "Dependency-Track has no project named ${DT_LOOKUP} (Jenkins uses projectName=image slug, tag PROJECT_ID)"
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
  echo "  AUTO_FIX=1 bash paas/scripts/verify-security-pipeline-lab.sh"
  echo "  bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
  echo "  bash paas/scripts/setup-security-lab.sh"
  echo "  bash paas/scripts/sign-all-deployed-paas-images-lab.sh   # after git pull"
  echo "  PROJECT_ID=<uuid> python3 paas/scripts/trigger-paas-deploy-lab.py"
  echo "  # wait Jenkins SUCCESS; re-run this script"
  exit 1
fi
