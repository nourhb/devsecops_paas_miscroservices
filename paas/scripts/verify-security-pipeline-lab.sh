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

if [[ -n "${PROJECT_ID}" && -z "${PROJECT_NAME}" ]]; then
  if kubectl get deployment postgres -n paas >/dev/null 2>&1; then
    PROJECT_NAME="$(kubectl exec -n paas deploy/postgres -- psql -U postgres -d paas -tAc \
      "SELECT \"projectName\" FROM \"Project\" WHERE id = '${PROJECT_ID}' LIMIT 1;" 2>/dev/null | tr -d ' \r\n' || true)"
  fi
  [[ -n "${PROJECT_NAME}" ]] || warn "could not resolve PROJECT_NAME from postgres (kubectl timeout?) — pass PROJECT_NAME=sanhome"
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
BUILDING="$(printf '%s' "${LAST_JSON}" | python3 -c "import json,sys; print('true' if json.load(sys.stdin).get('building') else 'false')" 2>/dev/null || echo false)"

if [[ "${BUILD}" == "0" || -z "${BUILD}" ]]; then
  fail "no Jenkins builds yet — deploy once from PaaS UI"
else
  echo "Build #${BUILD} result=${RESULT} building=${BUILDING}"
  CONSOLE="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${BUILD}/consoleText" 2>/dev/null || true)"

  if [[ "${BUILDING}" == "true" || "${RESULT}" == "NONE" || -z "${RESULT}" ]]; then
    warn "build #${BUILD} still running — wait, then: BUILD_NUMBER=${BUILD} PROJECT_ID=<uuid> bash paas/scripts/verify-security-pipeline-lab.sh"
    echo "     Poll: curl -fsS -u \"\$JENKINS_USERNAME:\$JENKINS_API_TOKEN\" \"${JENKINS_URL}/job/${JOB}/${BUILD}/api/json\" | python3 -c \"import json,sys; j=json.load(sys.stdin); print(j.get('result'), j.get('building'))\""
    echo ""
    echo "=== 4–5 skipped (build in progress) ==="
    exit 0
  fi

  if [[ -n "${PROJECT_ID}" ]] && [[ -n "${CONSOLE}" ]]; then
    if ! echo "${CONSOLE}" | grep -qF "${PROJECT_ID}"; then
      fail "build #${BUILD} is NOT for PROJECT_ID=${PROJECT_ID} — paas-deploy is shared across projects"
      echo "     Find the right build: bash paas/scripts/find-jenkins-build-for-project-lab.sh ${PROJECT_NAME:-<name>}" >&2
    else
      ok "build #${BUILD} belongs to PROJECT_ID=${PROJECT_ID}"
    fi
  elif [[ -n "${PROJECT_NAME}" && -n "${CONSOLE}" ]]; then
    if ! echo "${CONSOLE}" | grep -qE "projectName=${PROJECT_NAME}([^a-z0-9-]|$)|paas/${PROJECT_NAME}:"; then
      warn "build #${BUILD} may not be for PROJECT_NAME=${PROJECT_NAME} — set PROJECT_ID for certainty"
      echo "     bash paas/scripts/find-jenkins-build-for-project-lab.sh ${PROJECT_NAME}" >&2
    fi
  fi

  if [[ "${RESULT}" != "SUCCESS" ]]; then
    if echo "${CONSOLE}" | grep -qE '502 Bad Gateway|crane append|pushing image.*Harbor|harbor.*502'; then
      warn "build #${BUILD} is ${RESULT} — likely Harbor push (Step 6); Sonar/SCA may still be OK below"
    else
      fail "build #${BUILD} is ${RESULT} — need Jenkins SUCCESS for new image tag + GitOps deploy"
      if [[ -z "${BUILD_NUMBER}" ]]; then
        echo "     Tip: if an older build succeeded, re-run with BUILD_NUMBER=<n> PROJECT_ID=<uuid>"
      fi
      echo "     Step 3 failure? grep console:"
      echo "     curl -fsS -u \"\$JENKINS_USERNAME:\$JENKINS_API_TOKEN\" \"${JENKINS_URL}/job/${JOB}/${BUILD}/consoleText\" | grep -iE 'ERROR|unknown option|Step 3|Step 4'"
    fi
  else
    ok "last build SUCCESS"
  fi

  if echo "${CONSOLE}" | grep -q 'PAAS_STEP_SKIP step=4'; then
    fail "Step 4 skipped (fast pipeline or config)"
  elif echo "${CONSOLE}" | grep -qE 'Step 4|SCA \(Dependency-Check|PAAS_STEP_OK step=4|Dependency-Track upload|api/v1/bom'; then
    ok "Step 4 ran"
  else
    fail "Step 4 never ran (pipeline failed earlier)"
  fi

  if echo "${CONSOLE}" | grep -qiE 'non configuré|SONAR not set'; then
    fail "Sonar/DT credentials missing on build #${BUILD}"
  fi
  SONAR_ART=""
  SONAR_ART="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${BUILD}/artifact/paas-artifacts/sonar-scanner.log" 2>/dev/null || true)"
  sonar_step5_ok() {
    echo "${CONSOLE}" | grep -qE 'PAAS_STEP_OK step=5|analysis submitted for projectKey|ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' \
      || { [[ -n "${SONAR_ART}" ]] && echo "${SONAR_ART}" | grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS'; }
  }
  if sonar_step5_ok; then
    ok "Step 5 (Sonar) submitted on build #${BUILD}"
  elif echo "${CONSOLE}" | grep -qE 'PAAS_STEP_SKIP step=5|Fast pipeline: skip Step 5'; then
    fail "Step 5 skipped on build #${BUILD} (set JENKINS_PAAS_FAST_PIPELINE=false)"
  elif [[ -n "${SONAR_ART}" ]] && echo "${SONAR_ART}" | grep -qi 'Not authorized'; then
    fail "Step 5: Sonar Not authorized on build #${BUILD} — token missing in Scanner CLI 6 (need sonar.login). Run: bash paas/scripts/regenerate-sonar-token-lab.sh && bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
  elif [[ -n "${SONAR_TOKEN:-}" && -n "${SONAR_BASE_URL:-}" && -n "${PROJECT_NAME:-}" ]]; then
    # Jenkins may print PAAS_STEP_WARN while analysis still landed (or an older build's gate is OK).
    if curl -fsS -u "${SONAR_TOKEN}:" \
      "${SONAR_BASE_URL%/}/api/qualitygates/project_status?projectKey=${PROJECT_NAME}" 2>/dev/null \
      | grep -qE '"status":"OK"|"status":"ERROR"'; then
      if echo "${CONSOLE}" | grep -qiE 'PAAS_STEP_WARN step=5|scanner exit'; then
        warn "Step 5 Jenkins WARN on #${BUILD} but Sonar API has quality gate for ${PROJECT_NAME} — UI may still show data"
        ok "Step 5 (Sonar) — quality gate API OK for projectKey=${PROJECT_NAME}"
      else
        ok "Step 5 (Sonar) — quality gate API OK for projectKey=${PROJECT_NAME}"
      fi
    elif echo "${CONSOLE}" | grep -qE 'Step 5|SonarQube|Tests SAST|sonar-scanner|sonar-bash-rc-fix|marker=sonar-bash'; then
      if echo "${CONSOLE}" | grep -qiE 'paasStepWarn\(5|PAAS_STEP_WARN step=5|scanner exit|Not authorized'; then
        if echo "${CONSOLE}" | grep -qE '502 Bad Gateway|crane append|pushing image'; then
          if [[ "${RESULT}" == "SUCCESS" ]] && echo "${CONSOLE}" | grep -q 'PAAS_BUILD_COMPLETE'; then
            warn "Harbor 502 during Step 6 on #${BUILD} — Sonar may still have failed; verify image tag in registry"
          else
            warn "Step 5 may have been cut short — build did not finish cleanly (Harbor/earlier step)"
          fi
        fi
        if [[ -n "${SONAR_ART}" ]]; then
          echo "     sonar-scanner.log tail (build #${BUILD} artifact):" >&2
          echo "${SONAR_ART}" | tail -20 >&2
        else
          echo "     Fetch log: curl -fsS -u \"\$JENKINS_USERNAME:\$JENKINS_API_TOKEN\" \"${JENKINS_URL}/job/${JOB}/${BUILD}/artifact/paas-artifacts/sonar-scanner.log\" | tail -40" >&2
        fi
        fail "Step 5 ran but Sonar failed on build #${BUILD} — bash paas/scripts/diagnose-sonar-jenkins-lab.sh (or regenerate token)"
      else
        warn "Step 5 ran but no PAAS_STEP_OK — check Jenkins console for Sonar"
      fi
    else
      fail "Step 5 never ran on build #${BUILD}"
    fi
  elif echo "${CONSOLE}" | grep -qE 'Step 5|SonarQube|Tests SAST|sonar-scanner|sonar-bash-rc-fix|marker=sonar-bash'; then
    if echo "${CONSOLE}" | grep -qiE 'paasStepWarn\(5|PAAS_STEP_WARN step=5|scanner exit|Not authorized'; then
      fail "Step 5 ran but Sonar failed — set PROJECT_NAME and re-run, or: bash paas/scripts/regenerate-sonar-token-lab.sh"
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
  SONAR_TOTAL="$(curl -sS -m 15 -u "${SONAR_TOKEN}:" \
    "${SONAR_BASE_URL%/}/api/projects/search?ps=1" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('paging',{}).get('total',0))" 2>/dev/null || echo 0)"
  if [[ "${SONAR_TOTAL}" == "0" ]]; then
    VALID="$(curl -sS -m 10 -u "${SONAR_TOKEN}:" "${SONAR_BASE_URL%/}/api/authentication/validate" 2>/dev/null || true)"
    if ! echo "${VALID}" | grep -q '"valid":true'; then
      warn "SONAR_TOKEN invalid or Sonar unreachable at ${SONAR_BASE_URL} — bash paas/scripts/regenerate-sonar-token-lab.sh"
    fi
  fi
  SONAR_OK=0
  SONAR_KEYS=()
  if [[ -n "${PROJECT_NAME}" ]]; then
    SONAR_KEYS+=("${PROJECT_NAME}")
  fi
  if [[ -n "${PROJECT_ID}" ]]; then
    SONAR_KEYS+=("${PROJECT_ID}")
  fi
  if [[ -n "${CONSOLE:-}" ]]; then
    while IFS= read -r pk; do
      [[ -n "${pk}" ]] && SONAR_KEYS+=("${pk}")
    done < <(printf '%s\n' "${CONSOLE}" | grep -oE 'projectKey=[^[:space:]"'\''`]+' | sed 's/^projectKey=//' | sort -u)
  fi
  for SK in $(printf '%s\n' "${SONAR_KEYS[@]:-}" | awk '!seen[$0]++'); do
    [[ -z "${SK}" ]] && continue
    SQ="$(curl -sS -m 15 -u "${SONAR_TOKEN}:" \
      "${SONAR_BASE_URL%/}/api/qualitygates/project_status?projectKey=${SK}" 2>/dev/null || true)"
    if echo "${SQ}" | grep -q projectStatus; then
      ok "Sonar quality gate API responds for projectKey=${SK}"
      SONAR_OK=1
      break
    fi
  done
  if [[ "${SONAR_TOTAL}" -gt 0 ]]; then
    ok "Sonar has ${SONAR_TOTAL} project(s)"
    [[ "${SONAR_OK}" -eq 0 ]] && SONAR_OK=1
  elif [[ "${SONAR_OK}" -eq 0 ]]; then
    if [[ -n "${CONSOLE:-}" ]] && echo "${CONSOLE}" | grep -qE 'PAAS_STEP_OK step=5|analysis submitted for projectKey'; then
      warn "Step 5 submitted on build #${BUILD} but Sonar quality gate API not ready yet for ${PROJECT_NAME:-project} — wait 2–5 min and re-run with BUILD_NUMBER=${BUILD} PROJECT_ID=<uuid>"
    else
      fail "Sonar has no project / quality gate for ${PROJECT_NAME:-<name>} — run a build with Step 5 OK"
    fi
  fi
else
  fail "SONAR_BASE_URL / SONAR_TOKEN not set in shell — source ${ENV_FILE}"
fi

if [[ -n "${DEPENDENCY_TRACK_API_KEY:-}" && -n "${DEPENDENCY_TRACK_BASE_URL:-}" ]]; then
  DT_HTTP="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
    "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project" 2>/dev/null || echo 000)"
  if [[ "${DT_HTTP}" == "401" || "${DT_HTTP}" == "403" ]]; then
    fail "Dependency-Track API key rejected (HTTP ${DT_HTTP}) — run: bash paas/scripts/regenerate-dependency-track-api-key-lab.sh"
  elif [[ "${DT_HTTP}" != "200" ]]; then
    warn "Dependency-Track /api/v1/project HTTP ${DT_HTTP} (expected 200)"
  fi
  DT_LOOKUP="${PROJECT_NAME:-}"
  if [[ -z "${DT_LOOKUP}" && -n "${PROJECT_ID}" ]]; then
    DT_LOOKUP="${PROJECT_ID}"
  fi
  if [[ -n "${DT_LOOKUP}" ]]; then
    DT_COUNT="$(curl -sS -m 15 -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
      "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project?name=${DT_LOOKUP}" \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d) if isinstance(d,list) else 0)" 2>/dev/null || echo 0)"
    if [[ "${DT_COUNT}" -gt 0 ]]; then
      ok "Dependency-Track has project named ${DT_LOOKUP}"
    elif [[ -n "${PROJECT_ID}" ]]; then
      DT_TAG="$(curl -sS -m 15 -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY}" \
        "${DEPENDENCY_TRACK_BASE_URL%/}/api/v1/project" \
        | python3 -c "import json,sys; pid='${PROJECT_ID}'; d=json.load(sys.stdin); print(sum(1 for p in d if any((t.get('name') or '')==pid for t in (p.get('tags') or []))))" 2>/dev/null || echo 0)"
      if [[ "${DT_TAG}" -gt 0 ]]; then
        ok "Dependency-Track has project tagged with PROJECT_ID ${PROJECT_ID}"
      elif [[ -n "${CONSOLE:-}" ]] && echo "${CONSOLE}" | grep -qE 'api/v1/bom|PAAS_STEP_OK step=4'; then
        warn "Step 4 ran on #${BUILD} but DT project ${DT_LOOKUP} not found yet — upload may have failed; grep console for [sca]"
      else
        fail "Dependency-Track has no project named ${DT_LOOKUP} (Jenkins uses projectName=image slug, tag PROJECT_ID)"
      fi
    elif [[ -n "${CONSOLE:-}" ]] && echo "${CONSOLE}" | grep -qE 'api/v1/bom|PAAS_STEP_OK step=4'; then
      warn "Step 4 ran on #${BUILD} — set PROJECT_ID=<uuid> to verify DT project by tag"
    else
      fail "Dependency-Track has no project named ${DT_LOOKUP}"
    fi
  else
    warn "Set PROJECT_NAME=sanhome or PROJECT_ID=<uuid> to check Dependency-Track"
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
