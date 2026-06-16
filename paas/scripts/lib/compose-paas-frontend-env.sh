#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRONTEND_DIR="$(cd "${SCRIPT_DIR}/../../frontend" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

node_major() {
  node -e 'process.stdout.write(String(Number(process.versions.node.split(".")[0])))' 2>/dev/null || echo 0
}

run_compose() {
  node scripts/flatten-env-for-compose.mjs
}

if [[ "$(node_major)" -ge 14 ]]; then
  (cd "${FRONTEND_DIR}" && run_compose)
elif command -v docker >/dev/null 2>&1; then
  echo "==> System Node $(node -v 2>/dev/null || echo missing) — env:compose via node:20-alpine"
  docker run --rm \
    -v "${FRONTEND_DIR}:/app" \
    -w /app \
    node:20-alpine \
    node scripts/flatten-env-for-compose.mjs
else
  echo "ERROR: need Node.js 14+ or Docker to run paas/frontend env:compose" >&2
  exit 1
fi
