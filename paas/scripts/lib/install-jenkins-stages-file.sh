#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE="${JENKINS_STAGES_REMOTE_PATH:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
GENERATED="$(mktemp)"
trap 'rm -f "${GENERATED}"' EXIT

python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" > "${GENERATED}"
if ! grep -qF 'stage("Step 12 —' "${GENERATED}"; then
  echo "ERROR: generated stages file missing Step 12" >&2
  exit 1
fi
if ! grep -qF 'def coerceHarborHostForCosign' "${GENERATED}"; then
  echo "ERROR: generated stages file missing helpers (coerceHarborHostForCosign)" >&2
  exit 1
fi

jenkins_running_pod() {
  kubectl get pods -n "${JENKINS_NS}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | while read -r name; do
      [[ -z "${name}" ]] && continue
      if [[ "${name}" == *jenkins* ]]; then
        echo "${name}"
        return 0
      fi
    done
  return 1
}

install_via_kubectl() {
  local pod=""
  pod="$(jenkins_running_pod || true)"
  [[ -n "${pod}" ]] || return 1
  kubectl exec -n "${JENKINS_NS}" "${pod}" -- mkdir -p /var/jenkins_home/paas
  kubectl cp "${GENERATED}" "${JENKINS_NS}/${pod}:${REMOTE}"
  echo "OK: ${REMOTE} on Running pod ${JENKINS_NS}/${pod} (generated helpers+Steps 1-12)"
}

if install_via_kubectl; then
  exit 0
fi
if [[ -d /var/jenkins_home ]]; then
  sudo mkdir -p /var/jenkins_home/paas
  sudo cp "${GENERATED}" "${REMOTE}"
  sudo chmod 644 "${REMOTE}" 2>/dev/null || true
  echo "OK: ${REMOTE} on Jenkins host (generated helpers+Steps 1-12)"
  exit 0
fi
echo "ERROR: could not install stages file (no Running Jenkins pod in ${JENKINS_NS} and no /var/jenkins_home)" >&2
exit 1
