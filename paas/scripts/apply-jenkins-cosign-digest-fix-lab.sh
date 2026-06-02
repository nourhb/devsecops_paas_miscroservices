#!/usr/bin/env bash
# Push Jenkinsfile cosign digest signing fix to Jenkins (Kyverno verifyImages needs @sha256: signature).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
MARKER="cosign-digest-crane-bin-20260602"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi
if ! grep -qF "${MARKER}" "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing ${MARKER} — on this VM run: git pull origin main" >&2
  echo "  If still missing, push latest monorepo from your dev machine to GitHub first." >&2
  exit 1
fi
if grep -qF 'digest ref unavailable (crane/triangulate); tag sign only' "${JENKINSFILE}" \
  && ! grep -qF 'cosignSignImageShellSnippet' "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile still has OLD Step 9 only — need cosignSignImageShellSnippet from latest main" >&2
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
echo "==> Disable PaaS inline Jenkins overwrite (prevents reverting to old Step 9)"
upsert_env JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
fi

echo "==> Update Jenkins paas-deploy (full job config)"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo "==> Verify Jenkins job"
if ! bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"; then
  echo "ERROR: Jenkins job still outdated — see verify output above" >&2
  exit 1
fi

echo ""
echo "OK. Sign the current image if build already finished without digest sign:"
echo "  bash paas/scripts/sign-harbor-image-lab.sh 192.168.56.129:30002/paas/sanhome:<build#>"
echo ""
echo "Trigger a NEW build (not Replay). Console must show:"
echo "  marker=${MARKER}"
echo "  PAAS_IMAGE_DIGEST=...@sha256:..."
echo "  [cosign] signing digest ..."
echo "  [cosign] signing tag ..."
