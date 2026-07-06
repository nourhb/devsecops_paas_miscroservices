#!/usr/bin/env bash
# Lab helper script for rollout paas frontend recovery
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${SCRIPT_DIR}/lab-frontend-finish-rollout.sh" "$@"
