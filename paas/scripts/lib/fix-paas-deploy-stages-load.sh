#!/usr/bin/env bash
# Lab helper script for fix paas deploy stages load
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
