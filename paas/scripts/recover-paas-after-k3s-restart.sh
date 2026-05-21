#!/usr/bin/env bash
# Run after: sudo systemctl restart k3s, API recovery, or "Can't reach postgres.paas.svc.cluster.local".
# Brings Postgres up, verifies schema, syncs DATABASE_URL to frontend — does NOT delete PVC data.
#
# Usage (k3s master, repo root):
#   bash paas/scripts/recover-paas-after-k3s-restart.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "=== [1] Wait for API ==="
for i in $(seq 1 24); do
  if timeout 15 kubectl get --raw=/healthz >/dev/null 2>&1; then
    break
  fi
  sleep 5
  [[ "${i}" -eq 24 ]] && { echo "ERROR: API not ready"; exit 1; }
done

echo "=== [2] Postgres in ${PAAS_NS} ==="
bash "${SCRIPT_DIR}/deploy-paas-postgres-lab.sh"

echo "=== [3] Wait for frontend (if present) ==="
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  kubectl wait --for=condition=available deployment/frontend -n "${PAAS_NS}" --timeout=300s 2>/dev/null || true
fi

echo "=== [4] Schema (skip if User table exists) ==="
if kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='User'" 2>/dev/null | grep -q 1; then
  echo "User table already present — skipping prisma push"
else
  bash "${SCRIPT_DIR}/push-paas-schema-lab.sh"
fi

echo "=== [5] Sync env (DATABASE_URL + integrations) ==="
if [[ -f "${ENV_FILE}" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
else
  echo "WARN: ${ENV_FILE} missing — setting DATABASE_URL only"
  kubectl set env deployment/frontend -n "${PAAS_NS}" \
    DATABASE_URL='postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC'
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
fi

echo "=== [6] Health check ==="
bash "${SCRIPT_DIR}/check-paas-lab-health.sh"

echo ""
echo "OK — login: http://${NODE_IP}:30100/login"
