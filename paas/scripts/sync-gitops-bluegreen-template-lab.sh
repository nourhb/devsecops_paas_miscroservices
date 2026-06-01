#!/usr/bin/env bash
# Copy blue-green Helm templates into every project chart under ~/gitops (one-time after upgrade).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"
SRC="${REPO_ROOT}/paas/gitops/apps/simple-app/templates"

[[ -d "${GITOPS}/apps" ]] || { echo "ERROR: ${GITOPS}/apps missing" >&2; exit 1; }

for chart in "${GITOPS}"/apps/*/templates; do
  [[ -d "${chart}" ]] || continue
  cp -f "${SRC}/deployment-bluegreen.yaml" "${chart}/"
  cp -f "${SRC}/deployment.yaml" "${chart}/"
  cp -f "${SRC}/service.yaml" "${chart}/"
  echo "updated ${chart}"
done

echo "Commit in gitops repo:"
echo "  cd ${GITOPS} && git add apps && git commit -m 'chore: blue-green helm templates' && git push"
