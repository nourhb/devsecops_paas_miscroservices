#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="${ROOT}/.githooks"
MSG="${HOOKS}/commit-msg"
[[ -d "${HOOKS}" ]] || { echo "ERROR: missing ${HOOKS}" >&2; exit 1; }
[[ -f "${MSG}" ]] || { echo "ERROR: missing ${MSG}" >&2; exit 1; }
chmod +x "${HOOKS}/commit-msg" "${HOOKS}/prepare-commit-msg" 2>/dev/null || true
git -C "${ROOT}" config core.hooksPath .githooks
echo "OK: core.hooksPath=.githooks"
