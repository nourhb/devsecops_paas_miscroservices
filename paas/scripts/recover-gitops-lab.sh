#!/usr/bin/env bash
# Fix ~/gitops stuck rebase / detached HEAD, then push any local apps/ commits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/gitops-ensure-main.sh
source "${SCRIPT_DIR}/lib/gitops-ensure-main.sh"

REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
BRANCH="${GITOPS_BRANCH:-main}"

if [[ -z "${GITHUB_TOKEN:-}" ]] && [[ -f "${ENV_FILE}" ]]; then
  GITHUB_TOKEN="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  export GITHUB_TOKEN
fi
[[ -n "${GITHUB_TOKEN:-}" ]] || { echo "ERROR: set GITHUB_TOKEN or GITOPS_REPO_TOKEN" >&2; exit 1; }

AUTH_URL="https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git"

gitops_ensure_on_main "${GITOPS}" "${BRANCH}" "${AUTH_URL}"

pushd "${GITOPS}" >/dev/null
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "==> Commit local apps/ changes"
  git add apps/
  git commit -m "chore: recover gitops lab state $(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
fi
AHEAD="$(git rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo 0)"
if [[ "${AHEAD}" != "0" ]]; then
  echo "==> Push ${AHEAD} commit(s) to origin/${BRANCH}"
  git push "${AUTH_URL}" "${BRANCH}"
fi
popd >/dev/null
echo "OK: ${GITOPS} on ${BRANCH}"
