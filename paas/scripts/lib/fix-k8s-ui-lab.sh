#!/usr/bin/env bash
# Fix "Kubernetes API not configured" in PaaS UI (env + optional rebuild).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
REBUILD="${REBUILD:-0}"

echo "==> fix-k8s-ui-lab"

if [[ -f "${ENV_FILE}" ]]; then
  if grep -qE '^KUBE_CONFIG_PATH=' "${ENV_FILE}"; then
    echo "==> Removing KUBE_CONFIG_PATH from ${ENV_FILE} (breaks in-cluster API client)"
    sed -i '/^KUBE_CONFIG_PATH=/d' "${ENV_FILE}"
  fi
  if ! grep -qE '^KUBERNETES_ENABLED=true' "${ENV_FILE}"; then
    echo "KUBERNETES_ENABLED=true" >> "${ENV_FILE}"
    echo "==> Set KUBERNETES_ENABLED=true"
  fi
  if ! grep -qE '^NODE_IP=' "${ENV_FILE}"; then
    echo "NODE_IP=${NODE_IP}" >> "${ENV_FILE}"
  fi
fi

kubectl apply --validate=false -f "${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"
bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

if [[ "${REBUILD}" == "1" ]]; then
  echo "==> Rebuilding frontend (includes kubernetes-client in-cluster fix)"
  bash "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh"
else
  echo "==> Restarting frontend pod (env-only — set REBUILD=1 if UI still broken)"
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=180s
fi

echo "==> Health check (kubernetes.clientReady must be true after rebuild)"
curl -sS "http://${NODE_IP}:${PAAS_PORT}/api/health" | python3 -m json.tool 2>/dev/null \
  | grep -A6 '"kubernetes"' || curl -sS "http://${NODE_IP}:${PAAS_PORT}/api/health"

echo ""
bash "${SCRIPT_DIR}/probe-k8s-lab.sh" || true

echo ""
echo "If health still shows clientReady: false, run:"
echo "  REBUILD=1 bash paas/scripts/lib/fix-k8s-ui-lab.sh"
