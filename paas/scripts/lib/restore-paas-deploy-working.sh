#!/usr/bin/env bash
# Lab helper script for restore paas deploy working
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${SCRIPT_DIR}/lab-deploy-force-ready.sh"
