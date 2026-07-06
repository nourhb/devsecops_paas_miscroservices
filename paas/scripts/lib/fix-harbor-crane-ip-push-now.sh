#!/usr/bin/env bash
# Lab helper script for fix harbor crane ip push now
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PATCH_PY="${SCRIPT_DIR}/patch-crane-ip-first.py"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"
REMOTE="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
TMP="${TMPDIR:-/tmp}/paas-crane-ip-$$"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"

cd "${REPO_ROOT}"
mkdir -p "${TMP}"
trap 'rm -rf "${TMP}"' EXIT

echo "=============================================="
echo " FIX Harbor crane IP-first (patch live pod)"
echo "=============================================="

[[ -f "${PATCH_PY}" ]] || { echo "FAIL: missing ${PATCH_PY}" >&2; exit 1; }
kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null

if [[ -f "${JENKINSFILE}" ]]; then
  python3 "${PATCH_PY}" "${JENKINSFILE}" || true
fi

patch_and_push() {
  local name="$1"
  local local="${TMP}/${name}"
  kubectl cp -n "${JENKINS_NS}" "${JPOD}:${REMOTE}/${name}" "${local}" -c "${JCONTAINER}"
  python3 "${PATCH_PY}" "${local}"
  kubectl cp -n "${JENKINS_NS}" "${local}" "${JPOD}:${REMOTE}/${name}" -c "${JCONTAINER}"
}

echo "==> Patch paas-deploy-load-h2.groovy on pod"
patch_and_push "paas-deploy-load-h2.groovy"

echo "==> Patch paas-deploy-stages.groovy monolith on pod"
patch_and_push "paas-deploy-stages.groovy"

echo "==> Verify"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- sh -lc \
  "grep -n 'primary push ref (IP)\\|401 fallback' '${REMOTE}/paas-deploy-stages.groovy' | head -5"

if kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  grep -qF '401 fallback' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null; then
  echo "FAIL: pod still has 401 fallback" >&2
  exit 1
fi
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  grep -qF 'primary push ref (IP)' "${REMOTE}/paas-deploy-stages.groovy" \
  || { echo "FAIL: pod missing primary push ref (IP)" >&2; exit 1; }

echo ""
echo "OK. Trigger NEW paas-deploy (not Replay). Expect:"
echo "  primary push ref (IP):"
echo "  crane append attempt 1/... → 192.168.56.129:30002/..."
