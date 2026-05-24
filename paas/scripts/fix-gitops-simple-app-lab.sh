#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-117}"
GITOPS="${GITOPS:-${HOME}/gitops}"
[[ -n "${GITHUB_TOKEN:-}" ]] || { echo "ERROR: export GITHUB_TOKEN=ghp_..." >&2; exit 1; }
REMOTE="https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git"

cd "${GITOPS}"
if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
  echo "=== Abort stuck rebase ==="
  git rebase --abort 2>/dev/null || true
fi

echo "=== Sync with origin/main ==="
git fetch "${REMOTE}" main
git checkout main 2>/dev/null || git checkout -B main
git reset --hard FETCH_HEAD

VALUES="apps/simple-app/values.yaml"
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}"; exit 1; }
sed -i "s/^  tag:.*/  tag: \"${TAG}\"/" "${VALUES}"
sed -i '/^<<<<<<< /,/^>>>>>>> /d' "${VALUES}" 2>/dev/null || true

git add "${VALUES}"
git diff --cached --quiet || git commit -m "chore(simple-app): deploy image tag ${TAG}"
git push "${REMOTE}" main

echo "OK: GitOps main → tag ${TAG}"
echo "Sync Argo (after argocd login): argocd app sync paas-simple-app --force"
