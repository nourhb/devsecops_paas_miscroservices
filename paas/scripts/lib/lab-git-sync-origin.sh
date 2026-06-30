#!/usr/bin/env bash
# Lab VM: discard local repo drift and match origin/main (safe for deploy fixes).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"
branch="${LAB_GIT_BRANCH:-main}"
echo "[lab-git-sync] fetch + reset --hard origin/${branch}"
git fetch origin
git reset --hard "origin/${branch}"
git clean -fd paas/jenkins/.render-test /var/tmp/paas-deploy-bundle 2>/dev/null || true
rm -rf paas/jenkins/.render-test /var/tmp/paas-deploy-bundle 2>/dev/null || true
echo "[lab-git-sync] HEAD=$(git log -1 --oneline)"
chmod +x paas/scripts/lib/*.sh 2>/dev/null || true
echo "[lab-git-sync] done"
