#!/usr/bin/env bash
# Break the paas-deploy fix loop: install split files + push job wrapper via Jenkins API (not kubectl tee).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

echo "=============================================="
echo " BREAK paas-deploy loop (API job sync + verify)"
echo "=============================================="

# 1) Groovy bundles onto Jenkins PVC (kubectl)
echo "==> 1/3 Install 7-file CPS bundle into Jenkins pod"
SKIP_JOB_PATCH=1 bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

# 2) Job wrapper into Jenkins MEMORY (REST API — this is what builds actually use)
echo "==> 2/3 Push job wrapper via Jenkins REST API (--force-full)"
set -a
# shellcheck disable=SC1091
source "${ENV_FILE}" 2>/dev/null || true
set +a
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only

# 3) Hard verify LIVE config (never POST stale disk over API)
echo "==> 3/3 Verify LIVE job config (must match or we stop here)"
VERIFY_ONLY=1 bash "${SCRIPT_DIR}/reload-jenkins-paas-deploy-job.sh"

echo ""
echo "=============================================="
echo " LOOP BROKEN — safe to deploy."
echo ""
echo " Build console MUST show:"
echo "   marker=${CPS_MARKER}"
echo "   CPS split 7 files"
echo "   SEVEN [Pipeline] load lines"
echo "   *** BEGIN : Check Parameters ***"
echo ""
echo " If this fails again, rollback to June 17 (known working):"
echo "   LAB_ROLLBACK_CONFIRM=1 bash paas/scripts/lab.sh rollback-june17"
echo "=============================================="
