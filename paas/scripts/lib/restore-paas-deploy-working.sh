#!/usr/bin/env bash
# ONE SHOT: restore paas-deploy — delegates to lab-deploy-force-ready.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${SCRIPT_DIR}/lab-deploy-force-ready.sh"
