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
  git -C "${REPO_ROOT}" checkout -- paas/frontend/src/server/jenkins/embedded-jenkinsfile.ts 2>/dev/null \
    || true
else
  echo "WARN: node not on PATH — skip embed"
fi
echo "==> Push pipeline to Jenkins job paas-deploy"
resolve_jenkinsfile_lab() {
  local jenkinsfile="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
  local marker="${JENKINSFILE_MARKER:-nginx-conf-writefile-20260611}"
  local raw_url="${JENKINSFILE_RAW_URL:-https://raw.githubusercontent.com/nourhb/devsecops_paas_miscroservices/main/paas/jenkins/Jenkinsfile.paas-deploy}"
  local fresh="/tmp/Jenkinsfile.paas-deploy.${marker}.lab"
  has_marker() {
    local f="$1"
    [[ -f "${f}" ]] && grep -qF "${marker}" "${f}" && grep -qF 'writeNginxPaasDefaultConf' "${f}" && grep -qF 'def runPaasDeploy' "${f}"
  }
  if has_marker "${jenkinsfile}"; then
    echo "${jenkinsfile}"
    return 0
  fi
  echo "WARN: ${jenkinsfile} missing ${marker} — git pull" >&2
  git -C "${REPO_ROOT}" pull --ff-only 2>/dev/null || true
  if has_marker "${jenkinsfile}"; then
    echo "${jenkinsfile}"
    return 0
  fi
  echo "WARN: fetching Jenkinsfile from ${raw_url}" >&2
  curl -fsSL --retry 3 --connect-timeout 30 "${raw_url}" -o "${fresh}" || { echo "ERROR: curl failed for ${raw_url}" >&2; return 1; }
  has_marker "${fresh}" || { echo "ERROR: Downloaded Jenkinsfile still missing ${marker}" >&2; return 1; }
  echo "${fresh}"
}
JENKINSFILE="$(resolve_jenkinsfile_lab)"
export JENKINSFILE
load_jenkins_creds_for_sync() {
  local env_file="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
  if [[ -f "${env_file}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      local key="${line%%=*}"
      case "${key}" in
        JENKINS_USERNAME|JENKINS_API_TOKEN|JENKINS_USER|JENKINS_TOKEN|JENKINS_BASE_URL|JENKINS_PROBE_URL|\
        DEPENDENCY_TRACK_BASE_URL|DEPENDENCY_TRACK_API_KEY|JENKINS_DEPENDENCY_TRACK_BASE_URL|\
        SONAR_BASE_URL|SONAR_TOKEN|SONAR_HOST_URL)
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
      for key in JENKINS_USERNAME JENKINS_API_TOKEN JENKINS_USER JENKINS_TOKEN \
        DEPENDENCY_TRACK_BASE_URL DEPENDENCY_TRACK_API_KEY JENKINS_DEPENDENCY_TRACK_BASE_URL \
        SONAR_BASE_URL SONAR_TOKEN SONAR_HOST_URL; do
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
if [[ "${LAB_DT_SKIP_HEAL:-false}" == "true" ]]; then
  echo "SKIP: Dependency-Track (LAB_DT_SKIP_HEAL=true)"
elif ! bash "${SCRIPT_DIR}/lab-dependency-track.sh"; then
  echo "WARN: Dependency-Track heal incomplete — Jenkins sync continues; Step 4 may fail until API server is Running"
  LAB_DT_ENV_ONLY=true bash "${SCRIPT_DIR}/lab-dependency-track.sh" || true
fi
bash "${SCRIPT_DIR}/fix-paas-deploy-stages-load.sh"
bash "${SCRIPT_DIR}/lab-jenkins-agent-tools.sh" || echo "WARN: lab-jenkins-agent-tools.sh failed (pipeline auto-installs helm/crane on first build)"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only
echo "==> Disable stale inline Jenkinsfile sync on trigger"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
FRONTEND_ENV="${REPO_ROOT}/paas/frontend/.env"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  if [[ -f "${FRONTEND_ENV}" ]]; then
    if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${FRONTEND_ENV}" 2>/dev/null; then
      sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${FRONTEND_ENV}"
    else
      echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${FRONTEND_ENV}"
    fi
  fi
  if [[ "${PAAS_SKIP_ENV_SYNC:-}" == "1" ]]; then
    echo "SKIP: frontend env sync (PAAS_SKIP_ENV_SYNC=1 — run lab.sh env-quick separately)"
  else
    PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-1}" \
      ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || \
      echo "WARN: sync-paas-frontend-env-k8s.sh failed"
  fi
else
  echo "WARN: ${ENV_FILE} missing"
fi
bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh" || true
bash "${SCRIPT_DIR}/verify-jenkins-stages-on-cluster.sh" || {
  echo "ERROR: Jenkins stages file on cluster is stale — re-run: bash paas/scripts/lab.sh jenkins" >&2
  exit 1
}
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
