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

strip_kube_config_path() {
  local f="$1"
  [[ -f "${f}" ]] || return 0
  if grep -qE '^KUBE_CONFIG_PATH=' "${f}"; then
    sed -i '/^KUBE_CONFIG_PATH=/d' "${f}"
    echo "==> Removed KUBE_CONFIG_PATH from ${f}"
  fi
}

echo "==> fix-k8s-ui-lab"

# compose regenerates docker-compose.env from .env — strip both sources
strip_kube_config_path "${REPO_ROOT}/paas/frontend/.env"
strip_kube_config_path "${ENV_FILE}"
bash "${SCRIPT_DIR}/compose-paas-frontend-env.sh" 2>/dev/null || true
strip_kube_config_path "${ENV_FILE}"

if [[ -f "${ENV_FILE}" ]]; then
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
