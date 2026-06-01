#!/usr/bin/env bash
# Push ~/gitops to GitHub using GITOPS_REPO_TOKEN from docker-compose.env (not account password).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
BRANCH="${GITOPS_BRANCH:-main}"
REMOTE="${GITOPS_REMOTE:-https://github.com/nourhb/gitops.git}"

[[ -d "${GITOPS}/.git" ]] || {
  echo "ERROR: clone first: git clone ${REMOTE} ${GITOPS}" >&2
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
    echo "Create a GitHub PAT (repo scope) and set GITOPS_REPO_TOKEN=ghp_..." >&2
    exit 1
  fi
  export GITHUB_TOKEN
}

load_token
pushd "${GITOPS}" >/dev/null
if git diff --quiet && git diff --cached --quiet; then
  echo "Nothing to commit in ${GITOPS}"
else
  echo "WARN: uncommitted changes — commit first, then re-run: git add -A && git commit -m 'your message'"
  git status --short
  popd >/dev/null
  exit 1
fi

AHEAD="$(git rev-list --count "origin/${BRANCH}..HEAD" 2>/dev/null || echo 0)"
if [[ "${AHEAD}" == "0" ]]; then
  echo "No commits ahead of origin/${BRANCH}"
  popd >/dev/null
  exit 0
fi

echo "==> git push ${BRANCH} (${AHEAD} commit(s)) using GITOPS_REPO_TOKEN"
git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" "${BRANCH}"
popd >/dev/null
echo "OK: pushed ${GITOPS}"
