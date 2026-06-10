#!/usr/bin/env bash
# Ensure ~/gitops is on branch main (not detached HEAD) and not stuck in rebase.
# Usage: source lib/gitops-ensure-main.sh && gitops_ensure_on_main "${GITOPS}" "${BRANCH}" "${AUTH_URL}"

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
