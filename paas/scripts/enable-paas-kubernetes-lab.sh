#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
RBAC="${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"

if ! kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "ERROR: deployment/${DEPLOY_NAME} not found in ${PAAS_NS}" >&2
  exit 1
fi

echo "==> RBAC + ServiceAccount (in-cluster API; no kubeconfig mount required)"
kubectl apply -f "${RBAC}"

echo "==> Use ServiceAccount paas-frontend on deployment/${DEPLOY_NAME}"
kubectl patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
{
  "spec": {
    "template": {
      "spec": {
        "serviceAccountName": "paas-frontend"
      }
    }
  }
}
PATCH
)"

echo "==> Kubernetes env on pod (in-cluster: empty KUBE_CONFIG_PATH)"
kubectl set env deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}" \
  KUBERNETES_ENABLED=true \
  KUBE_CONFIG_PATH= \
  KUBE_TLS_SKIP_VERIFY=true

if [[ -f "${ENV_FILE}" ]]; then
  echo "==> Sync full docker-compose.env (keeps SMTP, Jenkins, etc.)"
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
else
  echo "WARN: ${ENV_FILE} missing — only KUBERNETES_* set; copy docker-compose.env.k8s.example"
  kubectl rollout restart deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}"
  kubectl rollout status deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s
fi

echo ""
echo "==> Verify"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- sh -c '
  echo KUBERNETES_ENABLED=$KUBERNETES_ENABLED
  echo KUBE_CONFIG_PATH=${KUBE_CONFIG_PATH:-<empty>}
  echo KUBERNETES_SERVICE_HOST=${KUBERNETES_SERVICE_HOST:-MISSING}
' 2>/dev/null || true

echo ""
echo "Refresh PaaS → Cluster status → K8s namespaces."
echo "Expected: Connected (green). If Connection failed: check RBAC / API server."
