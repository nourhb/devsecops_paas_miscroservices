#!/usr/bin/env bash
# Fix PaaS UI 500 after image-only rollout (restore env secret + probes + postgres).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
MANIFEST="${REPO_ROOT}/paas/k8s-manifests/hosted/frontend.yaml"
RECOVERY="${RECOVERY_IMAGE:-docker.io/library/paas-frontend:recovery}"

# shellcheck source=lab-frontend-lab-safety.sh
source "${SCRIPT_DIR}/lab-frontend-lab-safety.sh"

echo "==> 1/4 Restore deployment spec (envFrom, probes, ports) from manifest"
kubectl apply --validate=false -f "${MANIFEST}"

echo "==> 2/4 Sync paas-frontend-env secret + attach envFrom (no rollout yet)"
PAAS_SKIP_ROLLOUT=1 bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo "==> 3/4 Roll out recovery image (Recreate strategy — avoids stuck RollingUpdate)"
apply_lab_frontend_safety "${RECOVERY}" 1
if ! kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=180s 2>/dev/null; then
  echo "WARN: rollout slow — unstick"
  bash "${SCRIPT_DIR}/lab-frontend-rollout-unstick.sh"
fi

echo "==> 4/4 DB repair + health check"
bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "http://${NODE_IP}:${PAAS_PORT}/login" 2>/dev/null || echo 000)"
echo "Login HTTP: ${HTTP}"
[[ "${HTTP}" == "200" || "${HTTP}" == "307" || "${HTTP}" == "308" ]] || {
  echo "WARN: login still not 200 — check: kubectl logs -n ${PAAS_NS} deploy/frontend --tail=80" >&2
  exit 1
}
echo "OK: UI http://${NODE_IP}:${PAAS_PORT}/login"
