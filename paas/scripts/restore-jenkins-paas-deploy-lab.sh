#!/usr/bin/env bash
# Deploy the FULL Jenkinsfile.paas-deploy to Jenkins (fixes Step 4 SCA + Step 6 nginx $uri).
# Use this after partial patches or PaaS inline-sync overwrote the job with a stale script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

REQUIRED_MARKERS=(
  nginx-conf-writefile-20260611
  writeNginxPaasDefaultConf
  sca-npm-install-full-20260611
  sca-cyclonedx-node20-20260611
  cosign-digest-crane-bin-20260602
  multi-framework-20260611
)

cd "${REPO_ROOT}"

echo "==> 1. Resolve Jenkinsfile"
JENKINSFILE="${JENKINSFILE:-}"
if [[ -z "${JENKINSFILE}" ]]; then
  JENKINSFILE="$(bash "${SCRIPT_DIR}/resolve-jenkinsfile-lab.sh")"
fi
echo "    Using: ${JENKINSFILE}"

missing=0
for m in "${REQUIRED_MARKERS[@]}"; do
  if ! grep -qF "${m}" "${JENKINSFILE}" 2>/dev/null; then
    echo "FAIL: ${JENKINSFILE} missing ${m}" >&2
    missing=1
  fi
done
if [[ "${missing}" -ne 0 ]]; then
  echo "" >&2
  echo "Copy the fixed file from your dev machine:" >&2
  echo "  scp paas/jenkins/Jenkinsfile.paas-deploy user@192.168.56.129:/tmp/Jenkinsfile.paas-deploy" >&2
  echo "  JENKINSFILE=/tmp/Jenkinsfile.paas-deploy bash paas/scripts/restore-jenkins-paas-deploy-lab.sh" >&2
  exit 1
fi
echo "OK: all required markers present in Jenkinsfile"

echo "==> 2. Wait for Jenkins API"
JENKINS_WAIT_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
for i in $(seq 1 30); do
  if curl -fsS --connect-timeout 5 "${JENKINS_WAIT_URL}/api/json" >/dev/null 2>&1; then
    break
  fi
  sleep 3
  [[ "${i}" -eq 30 ]] && { echo "FAIL: Jenkins not up at ${JENKINS_WAIT_URL}" >&2; exit 1; }
done

echo "==> 3. Push FULL job config (--force-full — never merge partial CDATA)"
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo "==> 4. Block PaaS from overwriting Jenkins on next deploy trigger"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
fi

echo "==> 5. Sync ConfigMap (embedded Jenkinsfile in PaaS pod)"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || echo "WARN: ConfigMap sync skipped"

echo "==> 6. Verify Jenkins job script"
bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"

echo ""
echo "OK — trigger Build with Parameters (NOT Replay)."
echo "Console MUST show at pipeline start:"
echo "  marker=nginx-conf-writefile-20260611"
echo "  marker=sca-npm-install-full-20260611"
echo "  marker=sca-cyclonedx-node20-20260611"
echo "Step 4: [sca] no lockfile — full npm install then cyclonedx-npm"
echo "Step 6: [Pipeline] writeFile  then  [image] nginx crane append"
