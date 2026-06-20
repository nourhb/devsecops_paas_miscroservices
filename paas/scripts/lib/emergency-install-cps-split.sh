#!/usr/bin/env bash
# Self-contained fix for paas-deploy MethodTooLarge. No git pull required — only needs
# paas/jenkins/Jenkinsfile.paas-deploy on disk + kubectl + python3 on master.
set -euo pipefail
discover_repo_root() {
  if [[ -n "${REPO_ROOT:-}" && -f "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy" ]]; then
    echo "${REPO_ROOT}"
    return 0
  fi
  local script_root
  script_root="$(cd "$(dirname "$0")/../../.." && pwd)"
  if [[ -f "${script_root}/paas/jenkins/Jenkinsfile.paas-deploy" ]]; then
    echo "${script_root}"
    return 0
  fi
  for candidate in \
    "${HOME}/devsecops_paas_miscroservices" \
    "/home/master/devsecops_paas_miscroservices"; do
    if [[ -f "${candidate}/paas/jenkins/Jenkinsfile.paas-deploy" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}
REPO_ROOT="$(discover_repo_root)" || {
  echo "ERROR: cannot find repo — set REPO_ROOT=~/devsecops_paas_miscroservices" >&2
  exit 1
}
cd "${REPO_ROOT}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
PAAS_DIR="/var/jenkins_home/paas"
MARKER="helm-portable-20260620-cps-split"
LOAD_MARKER="paas-deploy-stages-load-20260620-cps-split"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=============================================="
echo " FIX paas-deploy MethodTooLarge"
echo " repo=${REPO_ROOT}"
echo "=============================================="

[[ -f "${JENKINSFILE}" ]] || { echo "ERROR: missing ${JENKINSFILE}" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required on master" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl required" >&2; exit 1; }

bash "${SCRIPT_DIR}/fix-paas-deploy-stages-load.sh"

echo ""
echo "==> Verification (must all print OK)"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- sh -c "
  grep -qF '${MARKER}' ${PAAS_DIR}/paas-deploy-stages-p3.groovy && echo OK:p3
  grep -qF 'def runPaasDeploy = {' ${PAAS_DIR}/paas-deploy-stages-p3.groovy && echo OK:run-def
  grep -qF '${LOAD_MARKER}' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:job-marker
  grep -qF 'load paasStagesP3' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:7file-load
  ! grep -qF 'load paasDeployStagesPath' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:no-monolithic-load
  ls -la ${PAAS_DIR}/paas-deploy-*.groovy
"
bash "${SCRIPT_DIR}/reload-jenkins-paas-deploy-job.sh"

echo ""
echo "=============================================="
echo " DONE. Start NEW build (NOT Replay)."
echo " Console MUST show:"
echo "   marker=${LOAD_MARKER}"
echo "   CPS split 7 files"
echo "   SEVEN [Pipeline] load lines"
echo "   *** BEGIN : Check Parameters ***"
echo "=============================================="
