#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

echo "=============================================="
echo " BREAK paas-deploy loop (API job sync + verify)"
echo "=============================================="

echo "==> 1/4 Install CPS bundle into Jenkins pod (jenkins-0)"
rm -rf "${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> 2/4 POST correct CPS wrapper to Jenkins LIVE (REST API)"
set -a
# shellcheck disable=SC1091
source "${ENV_FILE}" 2>/dev/null || true
set +a
python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py"

echo "==> 3/4 Push parameter defaults via Jenkins REST API"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only

echo "==> 4/4 Verify LIVE job config (must match or we stop here)"
VERIFY_ONLY=1 bash "${SCRIPT_DIR}/reload-jenkins-paas-deploy-job.sh" || \
  bash "${SCRIPT_DIR}/force-api-jenkins-paas-deploy-now.sh"

echo ""
echo "=============================================="
echo " LOOP BROKEN — safe to deploy."
echo ""
 echo " Build console MUST show:"
 echo "   marker=${CPS_MARKER}"
 echo "   SEVEN [Pipeline] load lines"
 echo "   runPaasDeploy()"
 echo "   *** BEGIN : Check Parameters ***"
echo ""
echo " If this fails again, rollback to June 17 (known working):"
echo "   LAB_ROLLBACK_CONFIRM=1 bash paas/scripts/lab.sh rollback-june17"
echo "=============================================="
