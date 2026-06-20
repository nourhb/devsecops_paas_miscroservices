#!/usr/bin/env bash
# One command: CPS split bundles + job wrapper + block PaaS UI from reverting Jenkins job.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"
OLD_MARKER="paas-deploy-stages-load-20260617"

cd "${REPO_ROOT}"

echo "=============================================="
echo " FORCE FIX paas-deploy (CPS split + anti-revert)"
echo "=============================================="

echo "==> 1/4 Install CPS bundles + patch + reload Jenkins LIVE job"
bash "${SCRIPT_DIR}/fix-paas-deploy-stages-load.sh"

echo "==> 2/4 Disable inline Jenkinsfile sync (stops UI from overwriting job)"
for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
  [[ -f "${f}" ]] || continue
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${f}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${f}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${f}"
  fi
  echo "   OK ${f}"
done

if command -v kubectl >/dev/null 2>&1 && kubectl get secret paas-frontend-env -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "==> 3/4 Sync env secret + restart PaaS frontend"
  PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-0}" ENV_FILE="${ENV_FILE}" \
    bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || echo "WARN: env sync failed — set secret manually"
else
  echo "==> 3/4 SKIP env sync (no paas-frontend-env secret)"
fi

echo "==> 4/4 Verify Jenkins LIVE job via API (builds use memory, not disk)"
bash "${SCRIPT_DIR}/reload-jenkins-paas-deploy-job.sh"

kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- sh -c "
  grep -qF 'load paasLoadH1' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:multi-load
  grep -qF 'runPaasDeploy()' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:run-call
  grep -qF 'helm-portable-20260620-cps-split' /var/jenkins_home/paas/paas-deploy-load-h1.groovy && echo OK:h1
  ls -la /var/jenkins_home/paas/paas-deploy-*.groovy
"

if command -v kubectl >/dev/null 2>&1; then
  POD_ENV="$(kubectl exec -n "${PAAS_NS}" deploy/paas-frontend --request-timeout=60s -- \
    printenv JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER 2>/dev/null || true)"
  echo "PaaS pod JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=${POD_ENV:-<unset>}"
  if [[ "${POD_ENV}" == "true" ]]; then
    echo "WARN: frontend pod still has sync=true — wait for rollout or run: kubectl rollout restart deploy/paas-frontend -n ${PAAS_NS}"
  fi
fi

echo ""
echo "=============================================="
echo " DONE — deploy from PaaS UI (NEW build, not Replay)"
echo " Console MUST show:"
echo "   marker=${CPS_MARKER}"
echo "   four [Pipeline] load lines"
echo "   *** BEGIN : Check Parameters ***"
echo "=============================================="
