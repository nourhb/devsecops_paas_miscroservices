#!/usr/bin/env bash
# Push Python SCA fix (Node requirements.txt BOM) to live Jenkins CPS bundle.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"

cd "${REPO_ROOT}"

if grep -qF 'Python BOM from requirements.txt (node — works without python3 on agent)' "${JENKINSFILE}" 2>/dev/null; then
  echo "==> Jenkinsfile has Python SCA node-first fix — full CPS re-render + push"
  SKIP_HARBOR_FIX_PUSH=1 bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
  exit $?
fi

echo "==> Jenkinsfile on VM is stale — patching live Jenkins pod (p2 + monolith)"
JPOD="${JENKINS_POD:-jenkins-0}"
JNS="${JENKINS_K8S_NAMESPACE:-cicd}"
REMOTE="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PATCH_PY="${SCRIPT_DIR}/patch-python-sca-node-first.py"
[[ -f "${PATCH_PY}" ]] || { echo "ERROR: missing ${PATCH_PY}" >&2; exit 1; }

for f in paas-deploy-stages-p2.groovy paas-deploy-stages.groovy; do
  kubectl exec -n "${JNS}" "${JPOD}" -c jenkins -- cat "${REMOTE}/${f}" > "${TMP}/${f}" 2>/dev/null || true
  [[ -s "${TMP}/${f}" ]] || continue
  python3 "${PATCH_PY}" "${TMP}/${f}"
  kubectl exec -i -n "${JNS}" "${JPOD}" -c jenkins -- tee "${REMOTE}/${f}" < "${TMP}/${f}" >/dev/null
  echo "OK: patched ${REMOTE}/${f}"
done

if [[ -f "${SCRIPT_DIR}/assemble-paas-deploy-monolith.sh" ]]; then
  bash "${SCRIPT_DIR}/assemble-paas-deploy-monolith.sh"
fi

echo ""
echo "OK: Python SCA patched on ${JNS}/${JPOD}. Trigger NEW paas-deploy build."
echo "Console should show: [sca] Python BOM from requirements.txt (node"
