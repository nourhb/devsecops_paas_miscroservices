#!/usr/bin/env bash
# One-shot: CPS-split bundle + Jenkins job wrapper (fixes MethodTooLarge on load).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

echo "==> 1/2 Install CPS-split load bundle"
bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> 2/2 Update paas-deploy job wrapper (multi load + runPaasDeploy)"
bash "${SCRIPT_DIR}/patch-jenkins-cps-split-job.sh"

echo ""
echo "Trigger NEW paas-deploy build. Console must show:"
echo "  marker=paas-deploy-stages-load-20260620-cps-split"
echo "  *** BEGIN : Check Parameters ***"
