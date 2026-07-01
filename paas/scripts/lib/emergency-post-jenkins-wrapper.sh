#!/usr/bin/env bash
# One-shot: POST CPS wrapper to Jenkins LIVE (works with XML-escaped OR CDATA config.xml).
set -euo pipefail
cd "$(dirname "$0")/../../.."
set -a
# shellcheck disable=SC1091
source paas/frontend/docker-compose.env 2>/dev/null || true
set +a
exec python3 paas/scripts/lib/post-paas-deploy-wrapper-live.py
