#!/usr/bin/env bash
# Install paas-deploy pipeline stages on jenkins-0.
# Lab uses 7-file CPS split + assembled monolith — delegate to the full fix script.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
echo "==> install-jenkins-stages-monolith.sh → fix-paas-deploy-cps-split-now.sh (CPS split + helm marker + return this)"
exec bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
