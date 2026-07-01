#!/usr/bin/env bash
# One-shot: unstick harbor-database-0 Pending (local-path PV node + control-plane taint).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "${SCRIPT_DIR}/lab-harbor-db-heal.sh"
