#!/usr/bin/env bash
# Continue push when fix-paas-deploy-cps-split-now.sh rendered OK but died before kubectl push
# (e.g. missing ensure-p3-orchestrator.sh on VM).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RENDER="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
SCA_MARKER='Python BOM from requirements.txt (node — works without python3 on agent)'

cd "${REPO_ROOT}"

[[ -f "${RENDER}/paas-deploy-stages-p2.groovy" ]] || {
  echo "FAIL: no render bundle at ${RENDER} — run push-jenkins-multi-framework-sca-now.sh first" >&2
  exit 1
}

grep -qF "${SCA_MARKER}" "${RENDER}/paas-deploy-stages-p2.groovy" \
  || { echo "FAIL: render p2 missing Python node SCA — update Jenkinsfile on VM first" >&2; exit 1; }

echo "==> Continuing from existing render at ${RENDER}"
SKIP_HARBOR_FIX_PUSH=1 bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
