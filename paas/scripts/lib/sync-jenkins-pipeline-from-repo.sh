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
load_jenkins_creds_for_sync() {
  local env_file="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
  if [[ -f "${env_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      local key="${line%%=*}"
      case "${key}" in
        JENKINS_USERNAME|JENKINS_API_TOKEN|JENKINS_USER|JENKINS_TOKEN|JENKINS_BASE_URL|JENKINS_PROBE_URL)
          export "${line}"
          ;;
      esac
    done < "${env_file}"
  fi
  [[ -z "${JENKINS_USERNAME:-}" && -n "${JENKINS_USER:-}" ]] && export JENKINS_USERNAME="${JENKINS_USER}"
  [[ -z "${JENKINS_API_TOKEN:-}" && -n "${JENKINS_TOKEN:-}" ]] && export JENKINS_API_TOKEN="${JENKINS_TOKEN}"
  if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
    if command -v kubectl >/dev/null 2>&1 && kubectl get secret paas-frontend-env -n "${PAAS_NS:-paas}" >/dev/null 2>&1; then
      local ns="${PAAS_NS:-paas}"
      for key in JENKINS_USERNAME JENKINS_API_TOKEN JENKINS_USER JENKINS_TOKEN; do
        local val
        val="$(kubectl get secret paas-frontend-env -n "${ns}" -o "jsonpath={.data.${key}}" 2>/dev/null | base64 -d 2>/dev/null || true)"
        [[ -n "${val}" ]] && export "${key}=${val}"
      done
      [[ -z "${JENKINS_USERNAME:-}" && -n "${JENKINS_USER:-}" ]] && export JENKINS_USERNAME="${JENKINS_USER}"
      [[ -z "${JENKINS_API_TOKEN:-}" && -n "${JENKINS_TOKEN:-}" ]] && export JENKINS_API_TOKEN="${JENKINS_TOKEN}"
    fi
  fi
}
load_jenkins_creds_for_sync
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
