#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
STAGES="${STAGES_FILE:-${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy}"
REMOTE="${JENKINS_STAGES_REMOTE_PATH:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"

if [[ ! -f "${STAGES}" ]]; then
  echo "ERROR: missing ${STAGES}" >&2
  exit 1
fi
if ! grep -qF 'stage("Step 12 —' "${STAGES}"; then
  echo "ERROR: stages file missing Step 12 — git pull" >&2
  exit 1
fi

install_via_kubectl() {
  local pod=""
  pod="$(kubectl get pods -n "${JENKINS_NS}" -l jenkins-jenkins-master=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${pod}" ]]; then
    pod="$(kubectl get pods -n "${JENKINS_NS}" -o name 2>/dev/null | grep -i jenkins | head -1 | sed 's|pod/||' || true)"
  fi
  [[ -n "${pod}" ]] || return 1
  kubectl exec -n "${JENKINS_NS}" "${pod}" -- mkdir -p /var/jenkins_home/paas
  kubectl cp "${STAGES}" "${JENKINS_NS}/${pod}:${REMOTE}"
  echo "OK: ${REMOTE} on pod ${JENKINS_NS}/${pod}"
  kubectl exec -n "${JENKINS_NS}" "${pod}" -- grep -qF 'stage("Step 12 —' "${REMOTE}"
}

if install_via_kubectl; then
  exit 0
fi
if [[ -d /var/jenkins_home ]]; then
  sudo mkdir -p /var/jenkins_home/paas
  sudo cp "${STAGES}" "${REMOTE}"
  sudo chmod 644 "${REMOTE}" 2>/dev/null || true
  echo "OK: ${REMOTE} on Jenkins host"
  exit 0
fi
echo "ERROR: could not install stages file (no Jenkins pod in ${JENKINS_NS} and no /var/jenkins_home)" >&2
exit 1
