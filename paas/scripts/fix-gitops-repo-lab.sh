#!/usr/bin/env bash
# Unstick ~/gitops after a failed repair/heal rebase (run before repair).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
# shellcheck source=gitops-lab-lib.sh
source "${SCRIPT_DIR}/gitops-lab-lib.sh"
AUTH_URL=""
if [[ -f "${ENV_FILE}" ]]; then
  GITHUB_TOKEN="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -n "${GITHUB_TOKEN}" ]] && AUTH_URL="https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git"
fi
echo "==> Reset ${GITOPS} to origin/main (drops local commits + conflict markers)"
gitops_reset_to_origin_main "${GITOPS}" main "${AUTH_URL}"
echo "OK: $(cd "${GITOPS}" && git status --short --branch | head -1)"
