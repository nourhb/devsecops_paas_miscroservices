#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

for i in $(seq 1 24); do
  timeout 15 kubectl get --raw=/healthz >/dev/null 2>&1 && break
  sleep 5
  [[ "${i}" -eq 24 ]] && { echo "API not ready"; exit 1; }
done

bash "${SCRIPT_DIR}/deploy-paas-postgres-lab.sh"

if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  kubectl wait --for=condition=available deployment/frontend -n "${PAAS_NS}" --timeout=300s 2>/dev/null || true
fi

if kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='User'" 2>/dev/null | grep -q 1; then
  echo "schema ok"
else
  bash "${SCRIPT_DIR}/push-paas-schema-lab.sh"
fi

if [[ -f "${ENV_FILE}" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
else
  kubectl set env deployment/frontend -n "${PAAS_NS}" \
    DATABASE_URL='postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC'
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
fi

bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
echo "login: http://${NODE_IP}:30100/login"
