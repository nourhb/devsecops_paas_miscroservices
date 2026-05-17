#!/usr/bin/env bash
# Regenerate docker-compose.env from .env (no npm required).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if command -v node >/dev/null 2>&1 && [[ -f scripts/flatten-env-for-compose.mjs ]]; then
  exec node scripts/flatten-env-for-compose.mjs "$@"
fi
if command -v python3 >/dev/null 2>&1 && [[ -f scripts/flatten-env-for-compose.py ]]; then
  exec python3 scripts/flatten-env-for-compose.py "$@"
fi
echo "Need node or python3 to run flatten-env-for-compose." >&2
exit 1
