#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

diagnose_frontend() {
  echo "=== frontend deployment ==="
  kubectl describe deployment frontend -n "${PAAS_NS}" 2>/dev/null | tail -40 || true
  echo "=== pods ==="
  kubectl get pods -n "${PAAS_NS}" -o wide 2>/dev/null || true
  echo "=== recent events ==="
  kubectl get events -n "${PAAS_NS}" --sort-by='.lastTimestamp' 2>/dev/null | tail -25 || true
}

wait_for_frontend() {
  local timeout="${1:-600}"
  if ! kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout="${timeout}s"; then
    echo "ERROR: frontend rollout failed" >&2
    diagnose_frontend
    return 1
  fi
  kubectl wait --for=condition=available deployment/frontend -n "${PAAS_NS}" --timeout=120s
}

echo "==> Wait for k3s API (after VM boot this can take 1–3 min)"
for i in $(seq 1 36); do
  if timeout 15 kubectl get --raw=/healthz >/dev/null 2>&1; then
    echo "OK: Kubernetes API ready (attempt ${i})"
    break
  fi
  sleep 5
  [[ "${i}" -eq 36 ]] && { echo "ERROR: k8s API not ready — run: sudo systemctl status k3s" >&2; exit 1; }
done

POSTGRES_UP=0
if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  if kubectl wait --for=condition=available deployment/postgres -n "${PAAS_NS}" --timeout=30s 2>/dev/null; then
    POSTGRES_UP=1
  fi
fi

if [[ "${POSTGRES_UP}" -eq 0 ]]; then
  echo "==> Hold frontend until Postgres is up (prevents Prisma login errors on reboot)"
  if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
    kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
  fi
else
  echo "==> Postgres already available — not scaling frontend down"
fi

echo "==> Postgres in namespace ${PAAS_NS} (PVC keeps users/projects)"
bash "${SCRIPT_DIR}/deploy-paas-postgres-lab.sh"
bash "${SCRIPT_DIR}/wait-for-postgres-lab.sh"

if kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='User'" 2>/dev/null | grep -q 1; then
  echo "schema ok"
else
  bash "${SCRIPT_DIR}/push-paas-schema-lab.sh"
fi

if [[ -f "${ENV_FILE}" ]]; then
  PAAS_SKIP_ROLLOUT=1 ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || {
    echo "WARN: env sync failed — starting frontend with existing deployment env" >&2
  }
else
  kubectl set env deployment/frontend -n "${PAAS_NS}" \
    DATABASE_URL='postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC'
fi

echo "==> Kyverno require-non-root workload patches (frontend/postgres)"
bash "${SCRIPT_DIR}/fix-paas-kyverno-workloads-lab.sh" || true

echo "==> Start frontend"
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1
  wait_for_frontend 600
else
  echo "ERROR: deployment/frontend missing in namespace ${PAAS_NS}" >&2
  exit 1
fi

for i in $(seq 1 12); do
  if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
    break
  fi
  echo "health check ${i}/12 failed (UI may still be rolling out); retry in 15s…"
  sleep 15
  [[ "${i}" -eq 12 ]] && { echo "recover finished but health check still failing"; diagnose_frontend; exit 1; }
done

echo "==> Platform bootstrap (Harbor cosign realm + Kyverno policy)"
bash "${SCRIPT_DIR}/platform-bootstrap-lab.sh" || true
if [[ -f "${ENV_FILE}" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true
  bash "${SCRIPT_DIR}/sync-jenkins-pipeline-from-repo.sh" || true
fi

echo ""
echo "OK — PaaS login: http://${NODE_IP}:30100/login"
