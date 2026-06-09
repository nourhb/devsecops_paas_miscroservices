#!/usr/bin/env bash
# Push Jenkinsfile env-loader fix to Jenkins (EMAIL_PASS with spaces / no . ./.env).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
MARKER="env-safe-dotenv-loader-20260601"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi
if ! grep -qF "${MARKER}" "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing ${MARKER} — git pull on this VM first" >&2
  exit 1
fi

echo "==> Jenkinsfile OK (${MARKER})"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || true

upsert_env() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || return 0
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}
echo "==> Disable PaaS inline Jenkins overwrite (use repo Jenkinsfile via ConfigMap + this script)"
upsert_env JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
fi

echo "==> Update Jenkins paas-deploy (full job config — not merge-only)"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
# Never use --force without --force-full here (merged-cdata drops markers Jenkins verify needs).

echo "==> Verify Jenkins job contains env loader fix"
if ! bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"; then
  echo "ERROR: Jenkins job still outdated — see verify output above" >&2
  exit 1
fi

echo ""
echo "OK. Trigger a NEW Deploy from PaaS (not Rebuild #271)."
echo "Console must show: [paas-jenkinsfile] marker=${MARKER}"
echo "Step 3 must show: [env] loaded N variable(s) ... EMAIL_PASS=<redacted>"
