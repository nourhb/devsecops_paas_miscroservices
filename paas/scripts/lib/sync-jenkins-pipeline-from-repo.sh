#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
EMBED="${REPO_ROOT}/paas/frontend/scripts/embed-jenkinsfile.mjs"
if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi
echo "==> Embed Jenkinsfile into frontend bundle"
if command -v node >/dev/null 2>&1; then
  node "${EMBED}" || echo "WARN: embed-jenkinsfile failed — Jenkins sync still uses ${JENKINSFILE}"
else
  echo "WARN: node not on PATH — skip embed"
fi
echo "==> Push pipeline to Jenkins job paas-deploy"
JENKINSFILE="$(bash "${SCRIPT_DIR}/resolve-jenkinsfile-lab.sh")"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
echo "==> Disable stale inline Jenkinsfile sync on trigger"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || \
    echo "WARN: sync-paas-frontend-env-k8s.sh failed"
else
  echo "WARN: ${ENV_FILE} missing"
fi
bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh" || true
if command -v kubectl >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true
fi
echo "==> Rebuild PaaS frontend image (TypeScript promote/artifact fixes require docker build, not rollout restart)"
if [[ "${SKIP_FRONTEND_REBUILD:-false}" != "true" ]] && [[ -f "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh" || echo "WARN: frontend rebuild failed — run: bash paas/scripts/lab.sh frontend"
else
  echo "WARN: skipped frontend rebuild (set SKIP_FRONTEND_REBUILD=false to enable)"
fi
echo "OK: Jenkins job updated."
