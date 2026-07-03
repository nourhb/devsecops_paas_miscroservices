#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
PAAS_DIR="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"

cd "${REPO_ROOT}"

echo "==> 1/3 Render + install CPS bundle"
bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> 2/3 Verify p3 entrypoint in rendered bundle"
grep -F 'def runPaasDeploy' "${RENDER_DIR}/paas-deploy-stages-p3.groovy" | tail -1
grep -qF 'return this' "${RENDER_DIR}/paas-deploy-stages-p3.groovy" \
  || echo "WARN: p3 missing return this (wrapper uses paasMain.runPaasDeploy())"

echo "==> 3/3 Patch job wrapper (paasMain = load p3)"
bash "${SCRIPT_DIR}/patch-jenkins-cps-split-job.sh"

echo ""
echo "OK — trigger a new paas-deploy build."
