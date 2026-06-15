#!/usr/bin/env bash
# Shared GitOps lab helpers (source from other scripts; do not execute directly).
gitops_abort_rebase() {
  local repo="${1:?repo path}"
  [[ -d "${repo}/.git" ]] || return 0
  pushd "${repo}" >/dev/null
  if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
    echo "==> gitops: abort stuck rebase in ${repo}"
    git rebase --abort 2>/dev/null || rm -rf .git/rebase-merge .git/rebase-apply
  fi
  popd
}

gitops_fetch_origin() {
  local repo="${1:?repo path}"
  local branch="${2:-main}"
  local auth_url="${3:-}"
  pushd "${repo}" >/dev/null
  if [[ -n "${auth_url}" ]]; then
    git fetch "${auth_url}" "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null \
      || git fetch "${auth_url}" "${branch}" 2>/dev/null \
      || git fetch origin "${branch}" 2>/dev/null \
      || true
  else
    git fetch origin "${branch}" 2>/dev/null || true
  fi
  popd
}

gitops_local_ahead_of_origin() {
  local repo="${1:?repo path}"
  local branch="${2:-main}"
  pushd "${repo}" >/dev/null
  git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 0
  popd
}

gitops_push_main() {
  local repo="${1:?repo path}"
  local branch="${2:-main}"
  local auth_url="${3:?auth url}"
  pushd "${repo}" >/dev/null
  local ahead
  ahead="$(git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 0)"
  if [[ "${ahead}" == "0" ]]; then
    echo "Nothing to push (already up to date with origin/${branch})"
    popd >/dev/null
    return 0
  fi
  echo "==> git push origin ${branch} (${ahead} commit(s))"
  if ! git push "${auth_url}" "HEAD:refs/heads/${branch}"; then
    echo "ERROR: git push failed" >&2
    popd >/dev/null
    return 1
  fi
  git fetch "${auth_url}" "+refs/heads/${branch}:refs/remotes/origin/${branch}" 2>/dev/null || true
  ahead="$(git rev-list --count "origin/${branch}..HEAD" 2>/dev/null || echo 0)"
  if [[ "${ahead}" != "0" ]]; then
    echo "ERROR: still ${ahead} commit(s) ahead of origin/${branch} after push" >&2
    popd >/dev/null
    return 1
  fi
  echo "OK: pushed ${repo} @ $(git rev-parse --short HEAD)"
  popd >/dev/null
}

# Drop local commits/conflicts and match origin/main (lab repair always rewrites apps/<slug>).
gitops_reset_to_origin_main() {
  local repo="${1:?repo path}"
  local branch="${2:-main}"
  local auth_url="${3:-}"
  gitops_abort_rebase "${repo}"
  gitops_fetch_origin "${repo}" "${branch}" "${auth_url}"
  pushd "${repo}" >/dev/null
  if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
    git checkout -B "${branch}" "origin/${branch}"
  elif [[ -n "${auth_url}" ]] && git rev-parse FETCH_HEAD >/dev/null 2>&1; then
    git checkout -B "${branch}" FETCH_HEAD
  else
    echo "WARN: origin/${branch} not found — staying on current branch" >&2
    git checkout -B "${branch}" 2>/dev/null || true
  fi
  popd
}

gitops_ensure_on_main() {
  local repo="${1:?repo path}"
  local branch="${2:-main}"
  local auth_url="${3:-}"
  gitops_abort_rebase "${repo}"
  gitops_fetch_origin "${repo}" "${branch}" "${auth_url}"
  pushd "${repo}" >/dev/null
  local current
  current="$(git branch --show-current 2>/dev/null || true)"
  if [[ -z "${current}" || "${current}" != "${branch}" ]]; then
    echo "==> gitops: checkout ${branch} (was: ${current:-detached HEAD})"
    if git show-ref --verify --quiet "refs/remotes/origin/${branch}"; then
      git checkout -B "${branch}" "origin/${branch}"
    elif [[ -n "${auth_url}" ]] && git rev-parse FETCH_HEAD >/dev/null 2>&1; then
      git checkout -B "${branch}" FETCH_HEAD
    else
      git checkout -B "${branch}"
    fi
  fi
  popd
}

gitops_file_has_conflicts() {
  local path="${1:?file}"
  [[ -f "${path}" ]] && grep -q '^<<<<<<< ' "${path}" 2>/dev/null
}

gitops_pull_rebase_resolve_apps() {
  local auth_url="${1:-}"
  local branch="${2:-main}"
  local remote="${auth_url:-origin}"
  if git pull --rebase "${remote}" "${branch}" 2>/dev/null || git pull --rebase origin "${branch}"; then
    return 0
  fi
  if [[ ! -d .git/rebase-merge && ! -d .git/rebase-apply ]]; then
    return 1
  fi
  local f
  local resolved=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    if [[ "${f}" == apps/* ]]; then
      echo "==> gitops: resolve rebase conflict in ${f} (keep repaired chart)"
      git checkout --theirs -- "${f}"
      git add -- "${f}"
      resolved=1
    fi
  done < <(git diff --name-only --diff-filter=U 2>/dev/null || true)
  if [[ "${resolved}" -eq 1 ]]; then
    GIT_EDITOR=true git rebase --continue
    return 0
  fi
  git rebase --abort 2>/dev/null || true
  return 1
}
