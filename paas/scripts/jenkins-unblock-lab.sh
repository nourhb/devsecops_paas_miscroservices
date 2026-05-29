#!/usr/bin/env bash
# Fast unblock: free Jenkins executors in ~2 min (no frontend rebuild).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "=== Jenkins executor unblock (2 min) ==="
bash "${SCRIPT_DIR}/abort-jenkins-zombie-builds-lab.sh"

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
fi

if command -v python3 >/dev/null && [[ -f "${SCRIPT_DIR}/jenkins-configure-lab.py" ]]; then
  echo ""
  echo "==> Script Console cleanup (needs admin token)"
  python3 "${SCRIPT_DIR}/jenkins-configure-lab.py" || echo "WARN: script failed — set JENKINS_USERNAME=admin + API token"
fi

echo ""
bash "${SCRIPT_DIR}/jenkins-status-lab.sh"

echo ""
echo "If idleExecutors is still 0, cancel #90 in Jenkins UI (admin) then re-run this script."
echo "When idle >= 1: reset PaaS row + ONE new deploy only."
