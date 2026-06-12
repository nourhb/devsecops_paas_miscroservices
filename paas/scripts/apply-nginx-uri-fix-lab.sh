#!/usr/bin/env bash
# Fix SPA/Angular/Vite Step 6: MissingPropertyException: uri (stale Jenkins pipeline).
# Run on lab VM: bash paas/scripts/apply-nginx-uri-fix-lab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
MARKER='nginx-conf-writefile-20260611'

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${JENKINSFILE}" ]] || die "missing ${JENKINSFILE} — git pull first"
grep -qF "${MARKER}" "${JENKINSFILE}" || die "repo Jenkinsfile missing ${MARKER} — git pull"
grep -qF 'writeNginxPaasDefaultConf' "${JENKINSFILE}" || die "repo Jenkinsfile missing writeNginxPaasDefaultConf"

echo "==> 1. Push fixed Jenkinsfile to Jenkins job paas-deploy"
JENKINSFILE="$(bash "${SCRIPT_DIR}/resolve-jenkinsfile-lab.sh")"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full || {
  echo "WARN: full push failed — emergency API patch"
  python3 "${SCRIPT_DIR}/patch-jenkins-nginx-uri-api-lab.py"
}
python3 "${SCRIPT_DIR}/patch-jenkins-nginx-uri-api-lab.py" || true

echo "==> 1b. Verify Jenkins config.xml contains ${MARKER}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a
JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_BASE_URL:-http://127.0.0.1:30090}}"
if [[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
  CFG="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${JENKINS_URL%/}/job/paas-deploy/config.xml" 2>/dev/null || true)"
  if echo "${CFG}" | grep -qF "${MARKER}" && echo "${CFG}" | grep -qF 'writeNginxPaasDefaultConf'; then
    echo "OK: Jenkins job script has ${MARKER} + writeNginxPaasDefaultConf"
  else
    die "Jenkins job still STALE after POST — console will fail Step 6 with MissingPropertyException: uri. Check Jenkins API / credentials."
  fi
else
  echo "WARN: set JENKINS_USERNAME + JENKINS_API_TOKEN in ${ENV_FILE} for config.xml verify"
fi

echo "==> 2. Update ConfigMap paas-jenkinsfile (mounted at /app/paas-bundled/...)"
if command -v kubectl >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || echo "WARN: ConfigMap sync failed"
else
  echo "WARN: kubectl not found — skip ConfigMap"
fi

echo "==> 3. Stop PaaS from overwriting Jenkins before each deploy"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  if command -v kubectl >/dev/null 2>&1; then
    ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true
  fi
else
  echo "WARN: ${ENV_FILE} missing — manually set JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false on frontend pod"
fi

echo "==> 4. Verify Jenkins job has ${MARKER}"
bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"

echo ""
echo "=============================================="
echo "DONE. Trigger build from Jenkins UI ONLY:"
echo "  http://192.168.56.129:30090/job/paas-deploy/build?delay=0sec"
echo "Console MUST show: marker=${MARKER}"
echo ""
echo "Do NOT deploy from PaaS UI until you run:"
echo "  bash paas/scripts/deploy-paas-frontend-k8s.sh"
echo "(rebuilds frontend with fixed embedded Jenkinsfile)"
echo "=============================================="
