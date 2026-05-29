#!/usr/bin/env bash
# Fast unblock: free Jenkins executors in ~3 min (no frontend rebuild).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "=== Jenkins executor unblock ==="
echo "NOTE: run ONCE — do not loop this script while a build is running."

bash "${SCRIPT_DIR}/abort-jenkins-zombie-builds-lab.sh"

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
fi

# Prefer loopback on the VM (NodePort can refuse during pod restart)
export JENKINS_PROBE_URL="${JENKINS_PROBE_URL:-http://127.0.0.1:30090}"
# shellcheck source=lib/wait-jenkins-api.sh
source "${SCRIPT_DIR}/lib/wait-jenkins-api.sh"
wait_jenkins_api "${JENKINS_PROBE_URL}" 180

if command -v python3 >/dev/null && [[ -f "${SCRIPT_DIR}/jenkins-configure-lab.py" ]]; then
  echo ""
  echo "==> Script Console: stop in-memory builds + clear queue"
  if ! python3 "${SCRIPT_DIR}/jenkins-configure-lab.py"; then
    echo ""
    echo "WARN: Script Console failed."
    echo "  Set JENKINS_USERNAME=admin + admin API token in ${ENV_FILE}"
    echo "  Or use Jenkins UI → Script Console (admin) and run doStop on paas-deploy builds."
  fi
fi

echo ""
JENKINS_PROBE_URL="${JENKINS_PROBE_URL}" bash "${SCRIPT_DIR}/jenkins-status-lab.sh"

echo ""
echo "=== Next ==="
echo "  1. idleExecutors should be >= 1 (see Computers section above)"
echo "  2. kubectl exec ... UPDATE Deployment SET status=FAILED WHERE PENDING/DEPLOYING"
echo "  3. ONE deploy from PaaS — console must reach Step 1 in ~30s"
echo "  4. Do NOT run this unblock script again until that build finishes or fails"
