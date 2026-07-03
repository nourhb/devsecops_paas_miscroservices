#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> install-jenkins-stages-monolith.sh → fix-paas-deploy-cps-split-now.sh (CPS split + helm marker + return this)"
exec bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
