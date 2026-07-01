#!/usr/bin/env bash
# Push rendered CPS bundle to helm Jenkins StatefulSet pod (jenkins-0).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
REMOTE_DIR="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
DT_MARKER="${DT_STAGES_MARKER:-helm-portable-20260620-cps-split}"

BUNDLE_FILES=(
  paas-deploy-load-h1.groovy
  paas-deploy-load-h2.groovy
  paas-deploy-load-h3.groovy
  paas-deploy-stages-vars.groovy
  paas-deploy-stages-p1.groovy
  paas-deploy-stages-p2.groovy
  paas-deploy-stages-p3.groovy
  paas-deploy-stages.groovy
)

cd "${REPO_ROOT}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

ensure_rendered_bundle() {
  local stages="${RENDER_DIR}/paas-deploy-stages.groovy"
  local p3="${RENDER_DIR}/paas-deploy-stages-p3.groovy"
  local need=0
  if [[ ! -f "${stages}" ]]; then
    need=1
  elif ! grep -qF 'return this' "${stages}"; then
    echo "WARN: ${stages} missing 'return this' — re-rendering"
    need=1
  elif ! grep -qF 'def runPaasDeploy()' "${stages}"; then
    echo "WARN: ${stages} missing def runPaasDeploy() — re-rendering"
    need=1
  elif ! grep -qF "${DT_MARKER}" "${stages}"; then
    echo "WARN: ${stages} missing ${DT_MARKER} — re-rendering"
    need=1
  elif [[ ! -f "${p3}" ]] || ! grep -qF 'def runPaasDeploy()' "${p3}"; then
    echo "WARN: ${p3} missing runPaasDeploy orchestrator — re-rendering"
    need=1
  fi
  if [[ "${need}" == "1" ]]; then
    echo "==> Render CPS bundle to ${RENDER_DIR}"
    mkdir -p "${RENDER_DIR}"
    PAAS_RENDER_DIR="${RENDER_DIR}" RENDER_ONLY=1 bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"
  fi
}

ensure_rendered_bundle

bash "${SCRIPT_DIR}/ensure-p3-orchestrator.sh" "${RENDER_DIR}/paas-deploy-stages-p3.groovy"

for f in "${BUNDLE_FILES[@]}"; do
  [[ -f "${RENDER_DIR}/${f}" ]] || { echo "FAIL: missing ${RENDER_DIR}/${f}" >&2; exit 1; }
done

stages="${RENDER_DIR}/paas-deploy-stages.groovy"
grep -qF 'return this' "${stages}" || { echo "FAIL: ${stages} still missing return this after render" >&2; exit 1; }
grep -qF 'def runPaasDeploy()' "${stages}" || { echo "FAIL: ${stages} missing def runPaasDeploy()" >&2; exit 1; }

kubectl get pod -n "${JENKINS_NS}" "${JPOD}" --request-timeout=30s >/dev/null \
  || { echo "FAIL: pod ${JENKINS_NS}/${JPOD} not found" >&2; exit 1; }

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=60s \
  -- mkdir -p "${REMOTE_DIR}"

for f in "${BUNDLE_FILES[@]}"; do
  bytes="$(wc -c < "${RENDER_DIR}/${f}" | tr -d ' ')"
  echo "==> ${f} (${bytes} bytes) -> ${REMOTE_DIR}/${f}"
  kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=120s \
    -- tee "${REMOTE_DIR}/${f}" < "${RENDER_DIR}/${f}" >/dev/null
done

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=60s \
  -- grep -qF 'runPaasDeploySteps9_12' "${REMOTE_DIR}/paas-deploy-stages-p3.groovy"

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=60s \
  -- grep -qF 'return this' "${REMOTE_DIR}/paas-deploy-stages.groovy" \
  || { echo "FAIL: remote monolith missing return this after install" >&2; exit 1; }

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=60s \
  -- grep -qF 'def runPaasDeploy()' "${REMOTE_DIR}/paas-deploy-stages.groovy"

echo "OK: CPS bundle on ${JENKINS_NS}/${JPOD}:${REMOTE_DIR} (monolith has return this)"
