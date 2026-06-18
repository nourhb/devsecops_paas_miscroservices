#!/usr/bin/env bash
# Render paas-deploy-stages.groovy and install into Jenkins (/var/jenkins_home/paas/).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE="${JENKINS_STAGES_REMOTE_PATH:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
DT_MARKER="${DT_STAGES_MARKER:-dt-api-server-svc-20260617}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
KTO="${KUBECTL_REQUEST_TIMEOUT:-120s}"
LOCAL_STAGES="${PAAS_GENERATED_STAGES_PATH:-/var/tmp/paas-deploy-stages.groovy}"
GENERATED="$(mktemp)"
trap 'rm -f "${GENERATED}"' EXIT

kubectl_api_ok() {
  kubectl get --raw=/healthz --request-timeout=15s >/dev/null 2>&1
}

discover_jenkins_deploy() {
  for ns in ${JENKINS_K8S_NAMESPACE:-} cicd jenkins devsecops; do
    [[ -n "${ns}" ]] || continue
    kubectl get deploy jenkins -n "${ns}" --request-timeout=20s >/dev/null 2>&1 || continue
    echo "${ns}"
    return 0
  done
  return 1
}

verify_remote_stages() {
  local ns="$1"
  kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
    grep -qF "${DT_MARKER}" "${REMOTE}" 2>/dev/null \
    && kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
      grep -qF 'stage("Step 12 —' "${REMOTE}" 2>/dev/null
}

install_via_exec_tee() {
  local ns="$1"
  local bytes
  bytes="$(wc -c < "${GENERATED}" | tr -d ' ')"
  echo "==> Stream ${bytes} bytes to deploy/jenkins:${REMOTE} (kubectl exec tee — works when kubectl cp hangs)"
  kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
    mkdir -p /var/jenkins_home/paas
  kubectl exec -i -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
    tee "${REMOTE}" < "${GENERATED}" >/dev/null
}

install_via_kubectl_cp() {
  local ns="$1"
  local pod
  pod="$(kubectl get pods -n "${ns}" -l app=jenkins \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' --request-timeout=30s 2>/dev/null || true)"
  [[ -n "${pod}" ]] || return 1
  kubectl exec -n "${ns}" "${pod}" -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
    mkdir -p /var/jenkins_home/paas 2>/dev/null \
    || kubectl exec -n "${ns}" "${pod}" --request-timeout="${KTO}" -- mkdir -p /var/jenkins_home/paas
  kubectl cp "${GENERATED}" "${ns}/${pod}:${REMOTE}" -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" 2>/dev/null \
    || kubectl cp "${GENERATED}" "${ns}/${pod}:${REMOTE}" --request-timeout="${KTO}"
}

install_to_jenkins() {
  local ns="$1"
  if install_via_exec_tee "${ns}"; then
    :
  elif install_via_kubectl_cp "${ns}"; then
    echo "==> Installed via kubectl cp (tee failed)"
  else
    return 1
  fi
  verify_remote_stages "${ns}"
}

print_manual_install() {
  echo ""
  echo "Manual install (when k8s API is slow; file already on disk):"
  echo "  kubectl exec -i -n ${JENKINS_NS} deploy/jenkins --request-timeout=120s -- \\"
  echo "    tee ${REMOTE} < ${LOCAL_STAGES}"
  echo ""
  echo "Or wait for API, then: bash paas/scripts/lib/install-jenkins-stages-file.sh"
  echo "If API keeps resetting: sudo systemctl restart k3s && sleep 20"
}

python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" > "${GENERATED}" || {
  echo "ERROR: render-loadable-stages.py failed (see message above)" >&2
  exit 1
}
cp "${GENERATED}" "${LOCAL_STAGES}"
chmod 644 "${LOCAL_STAGES}" 2>/dev/null || true
echo "==> Rendered stages: ${LOCAL_STAGES} ($(wc -c < "${LOCAL_STAGES}" | tr -d ' ') bytes)"

if ! grep -qF 'def coerceHarborHostForCosign' "${GENERATED}"; then
  echo "ERROR: generated stages file missing helpers (coerceHarborHostForCosign)" >&2
  exit 1
fi
if ! grep -qF 'stage("Step 12 —' "${GENERATED}"; then
  echo "ERROR: generated stages file missing Step 12" >&2
  exit 1
fi
if ! grep -qF "${DT_MARKER}" "${GENERATED}"; then
  echo "ERROR: generated stages file missing ${DT_MARKER}" >&2
  exit 1
fi
if grep -qF 'def paasDeployInit' "${GENERATED}" || grep -qF 'def runPaasStep01' "${GENERATED}"; then
  echo "ERROR: generated stages file uses broken split layout — run: git pull && bash paas/scripts/lab.sh rollback-june17" >&2
  exit 1
fi
if ! grep -qF 'dt_upload_candidates' "${GENERATED}"; then
  echo "ERROR: generated stages still has legacy pick_dt_base — update Jenkinsfile.paas-deploy" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl missing — trying local /var/jenkins_home"
else
  if ! kubectl_api_ok; then
    echo "WARN: k8s API /healthz failed (connection reset / timeout) — stages saved locally only" >&2
    print_manual_install
    exit 1
  fi
  ns="$(discover_jenkins_deploy || true)"
  if [[ -n "${ns}" ]]; then
    echo "==> Installing stages to ${ns}/deploy/jenkins:${REMOTE}"
    if install_to_jenkins "${ns}"; then
      echo "OK: ${REMOTE} on ${ns}/deploy/jenkins (${DT_MARKER})"
      exit 0
    fi
    echo "ERROR: could not install to ${ns}/deploy/jenkins" >&2
    print_manual_install
    exit 1
  fi
  echo "WARN: no Jenkins deployment in cicd/jenkins"
fi

if [[ -d /var/jenkins_home ]]; then
  sudo mkdir -p /var/jenkins_home/paas
  sudo cp "${GENERATED}" "${REMOTE}"
  sudo chmod 644 "${REMOTE}" 2>/dev/null || true
  if ! grep -qF "${DT_MARKER}" "${REMOTE}" 2>/dev/null; then
    echo "ERROR: ${REMOTE} missing ${DT_MARKER} after copy" >&2
    exit 1
  fi
  echo "OK: ${REMOTE} on Jenkins host (${DT_MARKER})"
  exit 0
fi

echo "ERROR: could not install stages file" >&2
print_manual_install
exit 1
