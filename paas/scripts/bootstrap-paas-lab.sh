#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "========== [1/3] Postgres in namespace ${PAAS_NS} =========="
bash "${SCRIPT_DIR}/deploy-paas-postgres-lab.sh" || {
  echo "WARN: deploy-paas-postgres-lab.sh had errors — continuing if postgres pod is ready"
  kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s || true
}

if [[ "${SKIP_SCHEMA:-}" != "1" ]]; then
  echo ""
  echo "========== [2/3] Prisma schema (User table, etc.) =========="
  bash "${SCRIPT_DIR}/push-paas-schema-lab.sh"
else
  echo "SKIP_SCHEMA=1 — skipping prisma db push"
fi

if [[ -f "${REPO_ROOT}/paas/frontend/docker-compose.env" ]]; then
  echo ""
  echo "========== [3/3] Sync docker-compose.env → frontend pod =========="
  ENV_FILE="${REPO_ROOT}/paas/frontend/docker-compose.env" \
    bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || {
    echo "WARN: sync-paas-frontend-env-k8s.sh failed — set DATABASE_URL manually:"
    echo "  kubectl set env deployment/frontend -n ${PAAS_NS} DATABASE_URL=postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC"
  }
else
  echo "WARN: missing paas/frontend/docker-compose.env — copy from docker-compose.env.k8s.example"
fi

echo ""
echo "========== OK =========="
echo "PaaS UI: http://${NODE_IP}:30100/login"
echo "Register if this is a new Postgres volume."
echo "Lab notes: paas/scripts/LAB.md"
