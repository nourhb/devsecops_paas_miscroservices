#!/usr/bin/env bash
# Render CPS-split paas-deploy load bundles and install into Jenkins (/var/jenkins_home/paas/).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE_DIR="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
REMOTE_STAGES="${JENKINS_STAGES_REMOTE_PATH:-${REMOTE_DIR}/paas-deploy-stages.groovy}"
DT_MARKER="${DT_STAGES_MARKER:-helm-portable-20260620-cps-split}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
KTO="${KUBECTL_REQUEST_TIMEOUT:-120s}"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
BUNDLE_FILES=(
  paas-deploy-load-h1.groovy
  paas-deploy-load-h2.groovy
  paas-deploy-load-h3.groovy
  paas-deploy-stages.groovy
)

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

install_one_file() {
  local ns="$1"
  local local_path="$2"
  local remote_path="$3"
  local bytes
  bytes="$(wc -c < "${local_path}" | tr -d ' ')"
  echo "==> ${local_path##*/} → ${remote_path} (${bytes} bytes)"
  kubectl exec -i -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
    tee "${remote_path}" < "${local_path}" >/dev/null
}

verify_remote_bundle() {
  local ns="$1"
  local f remote
  for f in "${BUNDLE_FILES[@]}"; do
    remote="${REMOTE_DIR}/${f}"
    kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
      grep -qF "${DT_MARKER}" "${remote}" 2>/dev/null || return 1
  done
  kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
    grep -qF 'def runPaasDeploy = {' "${REMOTE_STAGES}" 2>/dev/null \
    && kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
      grep -qF 'runPaasDeploySteps9_12' "${REMOTE_STAGES}" 2>/dev/null
}

print_manual_install() {
  echo ""
  echo "Manual install (each file):"
  for f in "${BUNDLE_FILES[@]}"; do
    echo "  kubectl exec -i -n ${JENKINS_NS} deploy/jenkins -c ${JENKINS_CONTAINER} -- \\"
    echo "    tee ${REMOTE_DIR}/${f} < ${RENDER_DIR}/${f}"
  done
}

mkdir -p "${RENDER_DIR}"
python3 "${REPO_ROOT}/paas/jenkins/split-cps-hotspots.py" 2>/dev/null || true
python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" --out-dir "${RENDER_DIR}" || {
  echo "ERROR: render-loadable-stages.py failed" >&2
  exit 1
}

for f in "${BUNDLE_FILES[@]}"; do
  [[ -f "${RENDER_DIR}/${f}" ]] || { echo "ERROR: missing ${RENDER_DIR}/${f}" >&2; exit 1; }
  if ! grep -qF "${DT_MARKER}" "${RENDER_DIR}/${f}"; then
    echo "ERROR: ${f} missing ${DT_MARKER}" >&2
    exit 1
  fi
done

stages="${RENDER_DIR}/paas-deploy-stages.groovy"
if ! grep -qF 'def runPaasDeploy = {' "${stages}"; then
  echo "ERROR: stages file missing runPaasDeploy orchestrator" >&2
  exit 1
fi
if ! grep -qF 'stage("Step 12 —' "${stages}"; then
  echo "ERROR: stages file missing Step 12" >&2
  exit 1
fi
cp "${stages}" "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy"
echo "==> Rendered CPS-split bundle under ${RENDER_DIR}"
ls -la "${RENDER_DIR}"/paas-deploy-*.groovy

if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl missing — bundle on disk only at ${RENDER_DIR}" >&2
  exit 1
fi
if ! kubectl_api_ok; then
  echo "WARN: k8s API failed — bundle saved at ${RENDER_DIR}" >&2
  print_manual_install
  exit 1
fi
ns="$(discover_jenkins_deploy || true)"
if [[ -z "${ns}" ]]; then
  echo "ERROR: no Jenkins deployment found" >&2
  print_manual_install
  exit 1
fi
kubectl exec -n "${ns}" deploy/jenkins -c "${JENKINS_CONTAINER}" --request-timeout="${KTO}" -- \
  mkdir -p "${REMOTE_DIR}"
for f in "${BUNDLE_FILES[@]}"; do
  install_one_file "${ns}" "${RENDER_DIR}/${f}" "${REMOTE_DIR}/${f}"
done
verify_remote_bundle "${ns}"
echo "OK: CPS-split bundle on ${ns}/deploy/jenkins (${DT_MARKER})"

echo "==> Patch paas-deploy job wrapper (multi-load + runPaasDeploy)"
bash "${SCRIPT_DIR}/patch-jenkins-cps-split-job.sh"
