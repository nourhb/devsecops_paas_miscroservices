#!/usr/bin/env bash
# Deploy Step 4 SCA fix — always pushes the FULL Jenkinsfile (no regex patch; avoids breaking Step 6 nginx fix).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${SCRIPT_DIR}/restore-jenkins-paas-deploy-lab.sh"
