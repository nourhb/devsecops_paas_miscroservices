#!/usr/bin/env bash
# Force-fix Jenkins paas-deploy Step 6 uri crash (MissingPropertyException: uri).
# Works even when lab git repo is stale (raw URL fallback + API patch).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

cd "${REPO_ROOT}"

echo "==> 0. Emergency on-disk patch (Jenkins pod config.xml — no git pull required)"
bash "${SCRIPT_DIR}/patch-jenkins-nginx-uri-on-disk-lab.sh" || {
  echo "WARN: on-disk patch skipped or failed — trying API + full push"
}

echo "==> 1. Resolve Jenkinsfile (local git pull → raw GitHub fallback)"
JENKINSFILE="$(bash "${SCRIPT_DIR}/resolve-jenkinsfile-lab.sh")"
echo "    Using: ${JENKINSFILE}"

echo "==> 2. Push full pipeline to Jenkins"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full || {
  echo "WARN: create_jenkins failed — trying emergency API patch"
  export JENKINSFILE
  python3 "${SCRIPT_DIR}/patch-jenkins-nginx-uri-api-lab.py"
}

echo "==> 3. Emergency patch if Jenkins still stale"
export JENKINSFILE
python3 "${SCRIPT_DIR}/patch-jenkins-nginx-uri-api-lab.py" || true

echo "==> 4. Disable PaaS inline overwrite + sync env"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
fi

echo "==> 5. ConfigMap (PaaS bundled Jenkinsfile)"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true

echo "==> 6. Verify"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a
JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_BASE_URL:-http://127.0.0.1:30090}}"
if [[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
  CFG="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${JENKINS_URL%/}/job/paas-deploy/config.xml" 2>/dev/null || true)"
  if echo "${CFG}" | grep -qF 'nginx-conf-writefile-20260611' && echo "${CFG}" | grep -qF 'writeNginxPaasDefaultConf'; then
    echo "OK: Jenkins job has nginx-conf-writefile-20260611"
  else
    echo "ERROR: Jenkins job STILL missing nginx fix — check JENKINS_USERNAME/API_TOKEN and re-run" >&2
    exit 1
  fi
fi

echo ""
echo "Trigger Build with Parameters (NOT Replay):"
echo "  ${JENKINS_URL%/}/job/paas-deploy/build?delay=0sec"
echo "Console MUST show at start:"
echo "  marker=nginx-conf-writefile-20260611"
echo "At Step 6:"
echo "  [image] marker=nginx-conf-writefile-20260611 (writeFile default.conf ...)"
