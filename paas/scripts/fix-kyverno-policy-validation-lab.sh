#!/usr/bin/env bash
# Fix PaaS Security UI: Kyverno policy FAIL while Cosign OK (missing RBAC + ClusterPolicies).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"

cd "${REPO_ROOT}"

upsert_env() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

echo "==> 1. Frontend RBAC (list Kyverno ClusterPolicies)"
kubectl apply -f "${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"
bash "${SCRIPT_DIR}/enable-paas-kubernetes-lab.sh"

echo ""
echo "==> 2. ClusterPolicies (UI) — apply even if webhook is down"
bash "${SCRIPT_DIR}/apply-kyverno-policies-only-lab.sh" || bash "${SCRIPT_DIR}/apply-kyverno-policies-lab.sh" || true

echo ""
echo "==> 2b. Kyverno admission webhook (optional — cluster enforcement)"
if ! bash "${SCRIPT_DIR}/ensure-kyverno-lab.sh" 2>/dev/null; then
  echo "WARN: Kyverno webhook unhealthy — run: bash paas/scripts/recover-kyverno-lab.sh"
fi

echo ""
echo "==> 3. Env flags for Security API"
upsert_env POLICY_ENGINE "kyverno"
upsert_env KYVERNO_POLICIES_ENABLED "true"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo ""
echo "==> 4. Verify"
kubectl get clusterpolicies.kyverno.io require-signed-images require-non-root \
  -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction 2>/dev/null || true

kubectl auth can-i list clusterpolicies.kyverno.io \
  --as="system:serviceaccount:${PAAS_NS}:paas-frontend" 2>/dev/null || true

kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv KYVERNO_POLICIES_ENABLED POLICY_ENGINE 2>/dev/null || true

echo ""
echo "OK — refresh PaaS → Security. Kyverno should be OK and Deployment allowed when Cosign is verified."
echo "No new Jenkins build required if cosignSigned is already true for the current image tag."
