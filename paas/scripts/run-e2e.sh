#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"

echo "1) Deploy readiness (${BASE_URL})"
curl -sS "${BASE_URL}/api/platform/deploy-readiness" | head -c 2000 || true
echo ""

echo "2) Health"
curl -sS "${BASE_URL}/api/health" || true
echo ""

echo "3+) Infra/GitOps/cluster checks remain manual — see paas/TESTING.md."
