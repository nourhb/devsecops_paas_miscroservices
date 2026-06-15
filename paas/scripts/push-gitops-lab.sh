#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
BRANCH="${GITOPS_BRANCH:-main}"
REMOTE_HOST="${GITOPS_REMOTE_HOST:-github.com/nourhb/gitops.git}"
COMMIT_MSG="${1:-}"
# shellcheck source=gitops-lab-lib.sh
source "${SCRIPT_DIR}/gitops-lab-lib.sh"
[[ -d "${GITOPS}/.git" ]] || {
  echo "ERROR: clone first: git clone https://${REMOTE_HOST} ${GITOPS}" >&2
  exit 1
}
load_token() {
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    return 0
  fi
  if [[ ! -f "${ENV_FILE}" ]]; then
    echo "ERROR: set GITHUB_TOKEN or GITOPS_REPO_TOKEN in ${ENV_FILE}" >&2
    exit 1
  fi
  GITHUB_TOKEN="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  if [[ -z "${GITHUB_TOKEN}" || "${GITHUB_TOKEN}" == *your_* || "${GITHUB_TOKEN}" == *placeholder* ]]; then
    echo "ERROR: GITOPS_REPO_TOKEN missing or placeholder in ${ENV_FILE}" >&2
    exit 1
  fi
  export GITHUB_TOKEN
}
load_token
AUTH_URL="https://${GITHUB_TOKEN}@${REMOTE_HOST}"
gitops_ensure_on_main "${GITOPS}" "${BRANCH}" "${AUTH_URL}"
pushd "${GITOPS}" >/dev/null
if [[ -n "${COMMIT_MSG}" ]]; then
  if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git ls-files --others --exclude-standard apps/)" ]]; then
    echo "==> git add apps/"
    git add apps/
    if git diff --cached --quiet; then
      echo "No staged changes under apps/"
    else
      git commit -m "${COMMIT_MSG}"
    fi
  fi
elif ! git diff --quiet || ! git diff --cached --quiet; then
  echo "WARN: uncommitted changes in ${GITOPS}" >&2
  git status --short
  echo "Re-run with a commit message, e.g.:" >&2
  echo "  bash paas/scripts/push-gitops-lab.sh 'chore: blue-green helm templates'" >&2
  popd >/dev/null
  exit 1
fi
echo "==> git fetch + pull --rebase origin/${BRANCH}"
git fetch "${AUTH_URL}" "${BRANCH}" 2>/dev/null || git fetch origin "${BRANCH}"
if git rev-parse "origin/${BRANCH}" >/dev/null 2>&1; then
  gitops_abort_rebase "${GITOPS}"
  if ! gitops_pull_rebase_resolve_apps "${AUTH_URL}" "${BRANCH}"; then
    echo "ERROR: git pull --rebase failed — run: bash paas/scripts/repair-gitops-app-lab.sh <slug>" >&2
    popd >/dev/null
    exit 1
  fi
else
  echo "WARN: no origin/${BRANCH} yet — first push"
fi
AHEAD="$(git rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo 0)"
if [[ "${AHEAD}" == "0" ]]; then
  echo "Nothing to push (already up to date with origin/${BRANCH})"
  popd >/dev/null
  exit 0
fi
echo "==> git push origin ${BRANCH} (${AHEAD} commit(s))"
git push "${AUTH_URL}" "${BRANCH}"
popd >/dev/null
echo "OK: pushed ${GITOPS}"
