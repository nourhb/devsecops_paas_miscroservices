#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
set -a
source paas/frontend/docker-compose.env 2>/dev/null || true
set +a
exec python3 paas/scripts/lib/post-paas-deploy-wrapper-live.py
