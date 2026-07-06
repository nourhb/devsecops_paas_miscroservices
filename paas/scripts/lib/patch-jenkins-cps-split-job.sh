#!/usr/bin/env bash
# Lab helper script for patch jenkins cps split job
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
LOAD_MARKER="${PAAS_DEPLOY_STAGES_LOAD_MARKER:-paas-deploy-stages-load-20260620-cps-split}"
JOB_CFG="/var/jenkins_home/jobs/paas-deploy/config.xml"
source "${SCRIPT_DIR}/lab-jenkins-pod.sh"

echo "==> patch-jenkins-cps-split-job (ns=${JENKINS_NS})"

echo "==> Refresh CPS bundle on Jenkins pod (monolith paas-deploy-stages.groovy + split files)"
SKIP_JOB_PATCH=1 bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> POST 7-file CPS wrapper to Jenkins LIVE job"
set -a
source "${ENV_FILE}" 2>/dev/null || true
set +a
python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py"

echo "==> Reload Jenkins in-memory job (disk-only patch is NOT enough for builds)"
bash "${SCRIPT_DIR}/reload-jenkins-paas-deploy-job.sh"

jenkins_exec "${JENKINS_NS}" sh -c "
  grep -qF '${LOAD_MARKER}' ${JOB_CFG} && echo OK:job-marker
  grep -qF 'load paasStagesP3' ${JOB_CFG} && echo OK:cps-split-load
  grep -qF 'runPaasDeploy()' ${JOB_CFG} && echo OK:run-call
  ! grep -qF 'def paas = load paasDeployStages' ${JOB_CFG} && echo OK:no-monolith-load
"
