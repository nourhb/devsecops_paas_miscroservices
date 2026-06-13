#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
BRANCH="${GITOPS_BRANCH:-main}"
REMOTE_HOST="${GITOPS_REMOTE_HOST:-github.com/nourhb/gitops.git}"
COMMIT_MSG="${1:-}"
[[ -d "${GITOPS}/.git" ]] || {
  echo "ERROR: clone first: git clone https://${REMOTE_HOST} ${GITOPS}" >&2
  exit 1
}
gitops_ensure_on_main() {
  local repo="${1:?gitops repo path}"
  local branch="${2:-main}"
  local auth_url="${3:-}"
  [[ -d "${repo}/.git" ]] || {
    echo "ERROR: not a git repo: ${repo}" >&2
    return 1
  }
  pushd "${repo}" >/dev/null
  if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
    echo "==> gitops: abort stuck rebase in ${repo}"
    git rebase --abort 2>/dev/null || rm -rf .git/rebase-merge .git/rebase-apply
  fi
  local fetch_target="origin"
  if [[ -n "${auth_url}" ]]; then
    git fetch "${auth_url}" "${branch}" 2>/dev/null || true
    fetch_target="${auth_url}"
  else
    git fetch origin "${branch}" 2>/dev/null || true
  fi
  local current
  current="$(git branch --show-current 2>/dev/null || true)"
  if [[ -z "${current}" || "${current}" != "${branch}" ]]; then
    echo "==> gitops: checkout ${branch} (was: ${current:-detached HEAD})"
    if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
      git checkout -B "${branch}" "origin/${branch}"
    elif git rev-parse "${fetch_target}/${branch}" >/dev/null 2>&1; then
      git checkout -B "${branch}" "${fetch_target}/${branch}"
    else
      git checkout -B "${branch}"
    fi
  fi
  if git rev-parse "origin/${branch}" >/dev/null 2>&1; then
    echo "==> gitops: pull --rebase origin/${branch}"
    git pull --rebase origin "${branch}" 2>/dev/null \
      || git pull --rebase "${fetch_target}" "${branch}" 2>/dev/null \
      || true
  fi
  popd >/dev/null
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
  if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
    git rebase --abort 2>/dev/null || rm -rf .git/rebase-merge .git/rebase-apply
  fi
  git pull --rebase "${AUTH_URL}" "${BRANCH}" 2>/dev/null || git pull --rebase origin "${BRANCH}"
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
