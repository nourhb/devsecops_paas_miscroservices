#!/usr/bin/env bash
set -euo pipefail

# Creates local git branches from the folder snapshots in paas/test-app
BASE_DIR="paas/test-app"

for b in branch-A branch-B branch-C; do
  echo "Creating branch: test-${b}";
  git checkout -b "test-${b}" || git switch "test-${b}" || true
  rsync -a --delete ${BASE_DIR}/${b}/ .
  git add -A
  git commit -m "chore: add test-app ${b}" || echo 'no changes to commit'
  git push -u origin "test-${b}" || echo 'push skipped or failed (no remote)'
done

echo "Branches created locally: test-branch-A/B/C"
