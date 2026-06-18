#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
jenkinsfile_bundle() {
  cat "${JENKINSFILE}"
}
jenkinsfile_has_marker() {
  local marker="$1"
  grep -qF "${marker}" "${JENKINSFILE}" 2>/dev/null
}
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:30090}"
JOB="paas-deploy"
CRANE_MARKERS=(
  'crane-next16-202605-nodefix'
  'crane-next16-202605-j48300-split'
  'crane-next16-202605-j48300'
  'crane-next16-202605'
)
BROKEN_MUTATE_PATTERN='cmd=-c'
MUTATE_FIX_MARKERS=(
  'monorepo-app-root-20260531'
  'entrypoint=/app/start-paas.sh'
  'crane mutate OK'
)
ENV_LOADER_MARKER='env-safe-dotenv-loader-20260601'
COSIGN_DIGEST_MARKER='cosign-digest-crane-bin-20260602'
NGINX_CONF_MARKER='nginx-conf-writefile-20260611'
DT_API_SERVER_MARKER='dt-api-server-svc-20260617'
SCA_FULL_MARKER='sca-npm-install-full-20260611'
BROKEN_ENV_LOADER_PATTERN='. ./.env'
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
  if echo "${text}" | grep -qE 'crane-next16[-&#45;]+202605'; then
    return 0
  fi
  return 1
}
jenkins_job_has_stale_step6() {
  local cfg="$1"
  echo "${cfg}" | grep -qF 'run_with_keepalive npx next build --no-lint'
}
jenkins_text_has_mutate_fix() {
  local text="$1"
  local m
  for m in "${MUTATE_FIX_MARKERS[@]}"; do
    if echo "${text}" | grep -qF "${m}"; then
      return 0
    fi
  done
  return 1
}
jenkins_job_has_broken_mutate() {
  local cfg="$1"
  if echo "${cfg}" | grep -qF "${BROKEN_MUTATE_PATTERN}" && echo "${cfg}" | grep -qF 'require(\"./package.json\")'; then
    return 0
  fi
  if echo "${cfg}" | grep -qF "${BROKEN_MUTATE_PATTERN}" && echo "${cfg}" | grep -qF 'require("./package.json")'; then
    return 0
  fi
  return 1
}
echo "==> Local Jenkinsfile contains crane-path fix?"
if jenkins_text_has_crane_fix "$(jenkinsfile_bundle)"; then
  echo "OK: repo Jenkinsfile has crane-path fix"
else
  echo "FAIL: missing crane-next16 marker in Jenkinsfile — git pull origin main"
  exit 1
fi
echo "==> Local Jenkinsfile contains Step 6 mutate fix (start-paas.sh)?"
if jenkins_text_has_mutate_fix "$(jenkinsfile_bundle)"; then
  echo "OK: repo Jenkinsfile has crane mutate fix"
else
  echo "FAIL: missing monorepo-app-root-20260531 / start-paas.sh in Jenkinsfile — git pull origin main"
  exit 1
fi
echo "==> Local Jenkinsfile contains env-safe dotenv loader?"
if jenkinsfile_has_marker "${ENV_LOADER_MARKER}"; then
  echo "OK: repo Jenkinsfile has ${ENV_LOADER_MARKER}"
else
  echo "FAIL: missing ${ENV_LOADER_MARKER} in Jenkinsfile — git pull"
  exit 1
fi
echo "==> Local Jenkinsfile contains cosign digest signing fix?"
if jenkinsfile_has_marker "${COSIGN_DIGEST_MARKER}"; then
  echo "OK: repo Jenkinsfile has ${COSIGN_DIGEST_MARKER}"
else
  echo "FAIL: missing ${COSIGN_DIGEST_MARKER} in Jenkinsfile — git pull"
  exit 1
fi
echo "==> Local Jenkinsfile contains SPA/Angular nginx conf fix (writeFile, no Groovy \$uri)?"
if jenkinsfile_has_marker "${NGINX_CONF_MARKER}" && jenkinsfile_has_marker 'writeNginxPaasDefaultConf'; then
  echo "OK: repo Jenkinsfile has ${NGINX_CONF_MARKER}"
else
  echo "FAIL: missing ${NGINX_CONF_MARKER} / writeNginxPaasDefaultConf — git pull"
  exit 1
fi
echo "==> Local Jenkinsfile contains Step 4 SCA full npm install fix?"
if jenkinsfile_has_marker "${SCA_FULL_MARKER}" && jenkinsfile_has_marker 'full npm install then cyclonedx-npm'; then
  echo "OK: repo Jenkinsfile has ${SCA_FULL_MARKER}"
else
  echo "FAIL: missing ${SCA_FULL_MARKER} — git pull"
  exit 1
fi
echo "==> Local Jenkinsfile contains Step 4 Dependency-Track in-cluster api-server fix?"
if jenkinsfile_has_marker "${DT_API_SERVER_MARKER}" && jenkinsfile_has_marker 'dtrack-dependency-track-api-server'; then
  echo "OK: repo Jenkinsfile has ${DT_API_SERVER_MARKER}"
else
  echo "FAIL: missing ${DT_API_SERVER_MARKER} — git pull and bash paas/scripts/lab.sh jenkins"
  exit 1
fi
SONAR_STEP5_MARKER="paas-artifacts/sonar-scanner.log"
echo "==> Local Jenkinsfile contains Steps 1-12?"
if grep -qF 'def runPaasDeploy' "${JENKINSFILE}" && grep -qF 'stage("Step 12 —' "${JENKINSFILE}"; then
  echo "OK: monolithic Jenkinsfile has runPaasDeploy + Step 12"
else
  echo "FAIL: Jenkinsfile missing runPaasDeploy or Step 12 — git pull"
  exit 1
fi
if grep -qF 'load paasDeployStagesPath' "${JENKINSFILE}"; then
  echo "OK: Jenkinsfile uses load() split layout for Blue Ocean 12-step view"
fi
echo "==> Local Jenkinsfile contains Sonar Step 5 fix (java + scanner log)?"
if grep -qF "${SONAR_STEP5_MARKER}" "${JENKINSFILE}"; then
  echo "OK: repo Jenkinsfile has ${SONAR_STEP5_MARKER}"
else
  echo "FAIL: missing ${SONAR_STEP5_MARKER} — run: bash paas/scripts/lab.sh jenkins"
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
REMOTE_CHECK_TEXT="${CFG}"
if echo "${CFG}" | grep -qF 'paas.runPaasDeploy()' && echo "${CFG}" | grep -qF 'paas-monolithic-runPaasDeploy-20260618'; then
  echo "OK: Jenkins job uses monolithic runPaasDeploy() layout (June 17)"
  REMOTE_CHECK_TEXT="$(jenkinsfile_bundle)"
elif echo "${CFG}" | grep -qF 'runPaasStep12()' || echo "${CFG}" | grep -qF 'paasDeployInit()'; then
  echo "FAIL: Jenkins job still uses broken Blue Ocean split layout — run: bash paas/scripts/lab.sh jenkins"
  exit 1
elif echo "${CFG}" | grep -qF 'load paasDeployStagesPath' || echo "${CFG}" | grep -qF 'paas-deploy-stages-load-20260617'; then
  echo "WARN: Jenkins job uses legacy load()-only layout — run: bash paas/scripts/lab.sh jenkins"
  REMOTE_CHECK_TEXT="$(jenkinsfile_bundle)"
fi
if jenkins_job_has_stale_step6 "${CFG}"; then
  echo "FAIL: Jenkins still has OLD Step 6 (npx next build --no-lint in crane path)"
  echo "Fix: bash paas/scripts/lab.sh jenkins"
  exit 1
fi
if jenkins_job_has_broken_mutate "${CFG}"; then
  echo "FAIL: Jenkins still has BROKEN crane mutate (--cmd with nested quotes — Step 6 always fails)"
  echo "Fix: bash paas/scripts/lab.sh jenkins"
  echo "      Then redeploy (new build); console must show: [image] crane mutate OK"
  exit 1
fi
if jenkins_text_has_mutate_fix "${REMOTE_CHECK_TEXT}"; then
  echo "OK: Jenkins job has Step 6 mutate fix (start-paas.sh)"
elif jenkins_text_has_crane_fix "${REMOTE_CHECK_TEXT}"; then
  echo "FAIL: Jenkins has crane-next16 but NOT mutate fix — run bash paas/scripts/lab.sh jenkins"
  exit 1
fi
if echo "${REMOTE_CHECK_TEXT}" | grep -qF "${ENV_LOADER_MARKER}" \
  || echo "${REMOTE_CHECK_TEXT}" | grep -qF 'env-decode-node-20260601' \
  || echo "${REMOTE_CHECK_TEXT}" | grep -qF 'paasSourceBuildEnvShellSnippet'; then
  echo "OK: Jenkins job has env-safe .env loader (Node)"
else
  echo "FAIL: Jenkins job missing ${ENV_LOADER_MARKER} (builds fail on EMAIL_PASS with spaces)"
  echo "Fix: bash paas/scripts/lab.sh jenkins"
  exit 1
fi
if echo "${REMOTE_CHECK_TEXT}" | grep -qF 'Do not use ". ./.env"'; then
  echo "OK: Jenkins job uses Node .env loader (not raw . ./.env)"
elif echo "${CFG}" | grep -qF "${BROKEN_ENV_LOADER_PATTERN}"; then
  echo "FAIL: Jenkins job still sources ${BROKEN_ENV_LOADER_PATTERN} — run sync-jenkins-pipeline-from-repo.sh"
  exit 1
fi
if echo "${REMOTE_CHECK_TEXT}" | grep -qF "${COSIGN_DIGEST_MARKER}"; then
  echo "OK: Jenkins job has ${COSIGN_DIGEST_MARKER}"
elif echo "${CFG}" | grep -qF 'digest ref unavailable (crane/triangulate); tag sign only'; then
  echo "FAIL: Jenkins job still has OLD Step 9 cosign (tag-only) — run bash paas/scripts/lab.sh jenkins"
  exit 1
fi
if echo "${REMOTE_CHECK_TEXT}" | grep -qF "${SONAR_STEP5_MARKER}" \
  || echo "${REMOTE_CHECK_TEXT}" | grep -qF 'sonar-scanner.log' \
  || echo "${REMOTE_CHECK_TEXT}" | grep -qF 'sonar-scanner&#47;log' \
  || echo "${REMOTE_CHECK_TEXT}" | grep -qF 'pick_sonar_url'; then
  echo "OK: Jenkins job has Sonar Step 5 fix (${SONAR_STEP5_MARKER})"
else
  echo "FAIL: Jenkins job missing Sonar Step 5 fix — run: bash paas/scripts/lab.sh jenkins"
  exit 1
fi
SONAR_LOGIN_MARKERS=( 'sonar-scanner-cli6-login-20260607' 'sonar.login' "printf 'sonar.login" )
sonar_login_ok=0
for m in "${SONAR_LOGIN_MARKERS[@]}"; do
  if echo "${REMOTE_CHECK_TEXT}" | grep -qF "${m}"; then
    sonar_login_ok=1
    break
  fi
done
if [[ "${sonar_login_ok}" -eq 1 ]]; then
  echo "OK: Jenkins job has SonarScanner CLI 6 login (sonar.login)"
else
  echo "FAIL: Jenkins job missing sonar.login — run: bash paas/scripts/lab.sh jenkins"
  exit 1
fi
if { echo "${REMOTE_CHECK_TEXT}" | grep -qF "${NGINX_CONF_MARKER}" \
  || echo "${REMOTE_CHECK_TEXT}" | grep -qF '[image] marker=nginx-conf-writefile-20260611'; } \
  && echo "${REMOTE_CHECK_TEXT}" | grep -qF 'writeNginxPaasDefaultConf'; then
  echo "OK: Jenkins job has ${NGINX_CONF_MARKER} (SPA/Angular Step 6 uri fix)"
else
  STAGES_OK=0
  if echo "${CFG}" | grep -qF 'load paasDeployStagesPath'; then
    JNS="${JENKINS_K8S_NAMESPACE:-cicd}"
    JPOD="$(kubectl get pods -n "${JNS}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -iE '^jenkins' | head -1 || true)"
    if [[ -n "${JPOD}" ]] && kubectl exec -n "${JNS}" "${JPOD}" -- grep -qF 'writeNginxPaasDefaultConf' /var/jenkins_home/paas/paas-deploy-stages.groovy 2>/dev/null; then
      STAGES_OK=1
      echo "OK: stages file on ${JNS}/${JPOD} has writeNginxPaasDefaultConf (load() layout)"
    fi
  fi
  if [[ "${STAGES_OK}" -eq 0 ]]; then
    echo "FAIL: Jenkins job missing ${NGINX_CONF_MARKER} — Step 6 fails: MissingPropertyException: uri"
    echo "Fix: bash paas/scripts/lab.sh jenkins"
    echo "      Then Build with Parameters — do NOT Replay old builds"
    exit 1
  fi
fi
if echo "${REMOTE_CHECK_TEXT}" | grep -qF "${SCA_FULL_MARKER}" && echo "${REMOTE_CHECK_TEXT}" | grep -qF 'full npm install then cyclonedx-npm'; then
  echo "OK: Jenkins job has ${SCA_FULL_MARKER} (Step 4 SBOM for vite projects without lockfile)"
elif echo "${CFG}" | grep -qF 'sca-npm-install-nolock-20260611' \
  || echo "${CFG}" | grep -qF '--package-lock-only' && echo "${CFG}" | grep -qF 'no lockfile — npm install then cyclonedx-npm'; then
  echo "FAIL: Jenkins job has OLD/broken Step 4 SCA (package-lock-only or partial patch)"
  echo "Fix: bash paas/scripts/lab.sh jenkins"
  exit 1
else
  echo "FAIL: Jenkins job missing ${SCA_FULL_MARKER}"
  echo "Fix: bash paas/scripts/lab.sh jenkins"
  exit 1
fi
if echo "${CFG}" | grep -qF 'def runPaasDeploy'; then
  echo "OK: Jenkins job uses monolithic pipeline (def runPaasDeploy)"
  echo ""
  echo "Trigger a NEW build (not Replay) — full security pipeline should run."
  exit 0
fi
if jenkins_text_has_crane_fix "${CFG}"; then
  echo "OK: Jenkins job ${JOB} is up to date ($(wc -c <<< "${CFG}") bytes config)"
  echo ""
  echo "Trigger a NEW build: Jenkins → ${JOB} → Build with Parameters"
  echo "Do NOT click Replay on old failed builds."
  exit 0
fi
echo "FAIL: Jenkins job script missing Step 6 mutate fix — run bash paas/scripts/lab.sh jenkins"
exit 1
