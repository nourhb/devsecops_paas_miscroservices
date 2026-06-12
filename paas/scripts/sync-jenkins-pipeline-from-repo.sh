#!/usr/bin/env bash
# Push paas/jenkins/Jenkinsfile.paas-deploy to lab Jenkins (run on lab VM or dev machine with JENKINS_* in docker-compose.env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
EMBED="${REPO_ROOT}/paas/frontend/scripts/embed-jenkinsfile.mjs"

if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi

echo "==> Embed Jenkinsfile into frontend bundle (optional; needs Node 14+)"
if command -v node >/dev/null 2>&1; then
  node "${EMBED}" || echo "WARN: embed-jenkinsfile failed (host Node too old?) — Jenkins sync still uses ${JENKINSFILE}"
else
  echo "WARN: node not on PATH — skip embed; Jenkins sync uses ${JENKINSFILE} directly"
fi

echo "==> Push pipeline to Jenkins job paas-deploy"
JENKINSFILE="$(bash "${SCRIPT_DIR}/resolve-jenkinsfile-lab.sh")"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
python3 "${SCRIPT_DIR}/patch-jenkins-nginx-uri-api-lab.py" || true

echo "==> Stop PaaS UI from overwriting Jenkins with stale embedded Jenkinsfile"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || \
    echo "WARN: sync-paas-frontend-env-k8s.sh failed — set JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false manually"
else
  echo "WARN: ${ENV_FILE} missing — set JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false on the frontend pod"
fi

bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh" || true

echo ""
echo "=============================================="
echo "OK: Jenkins job updated."
echo "Next: Jenkins → paas-deploy → Build with Parameters"
echo "Console MUST show: marker=nginx-conf-writefile-20260611"
echo ""
echo "Why Vite/Angular failed but Next.js worked: static apps use nginx Step 6"
echo "(web-spa-static-20260529). Old Jenkinsfile had a Groovy \$uri bug there."
echo ""
echo "Do NOT use Replay on old builds — use Build with Parameters."
echo "Until frontend image is rebuilt, keep JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false"
echo "=============================================="
