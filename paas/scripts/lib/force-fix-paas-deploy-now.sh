#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

echo "=============================================="
echo " FORCE FIX paas-deploy (break loop + anti-revert)"
echo "=============================================="

echo "==> 1/3 Break loop (API wrapper + verify LIVE)"
bash "${SCRIPT_DIR}/break-paas-deploy-loop.sh"

echo "==> 2/3 Disable inline Jenkinsfile sync (stops UI from overwriting job)"
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
  echo "==> 3/3 Sync env secret + restart PaaS frontend"
  PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-0}" ENV_FILE="${ENV_FILE}" \
    bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || echo "WARN: env sync failed — set secret manually"
else
  echo "==> 3/3 SKIP env sync (no paas-frontend-env secret)"
fi

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
echo "   CPS split 7 files"
echo "   SEVEN [Pipeline] load lines"
echo "   *** BEGIN : Check Parameters ***"
echo ""
echo " If still broken: LAB_ROLLBACK_CONFIRM=1 bash paas/scripts/lab.sh rollback-june17"
echo "=============================================="
