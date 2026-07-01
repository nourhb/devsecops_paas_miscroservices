#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"
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

echo "==> Ensure k3s API (restart if needed after VM boot)"
bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || {
  echo "ERROR: k3s not running — fix k3s before PaaS recover" >&2
  exit 1
}

echo "==> Wait for k3s API (extra probe)"
for i in $(seq 1 60); do
  if lab_k8s_api_ready; then
    echo "OK: Kubernetes API ready (attempt ${i})"
    break
  fi
  sleep 5
  if [[ "${i}" -eq 60 ]]; then
    echo "ERROR: k8s API not ready after 5 min" >&2
    echo "  kubectl: $(command -v kubectl 2>/dev/null || echo missing)" >&2
    echo "  k3s: $(command -v k3s 2>/dev/null || echo missing)" >&2
    echo "  KUBECONFIG=${KUBECONFIG:-unset}" >&2
    echo "  HOME=${HOME:-unset}" >&2
    echo "  Fix: bash paas/scripts/lab.sh boot-install && sudo systemctl restart k3s" >&2
    exit 1
  fi
done

if ! kubectl get namespace "${PAAS_NS}" >/dev/null 2>&1; then
  echo "==> Namespace ${PAAS_NS} missing (k3s etcd was wiped?) — full lab bootstrap"
  bash "${SCRIPT_DIR}/lab-fresh-cluster.sh"
  exit $?
fi

if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
  echo "OK: PaaS already healthy — skip disruptive recover (boot service success)"
  bash "${SCRIPT_DIR}/lab-guard-cron.sh" install 2>/dev/null || true
  echo ""
  echo "OK — PaaS login: http://${NODE_IP}:30100/login"
  exit 0
fi

echo "==> Lightweight recover (quick-up — no k3s restart, no scale-to-0)"
export PAAS_BOOT_RECOVER=1
if bash "${SCRIPT_DIR}/lab-quick-up.sh"; then
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh" && exit 0
fi

echo "==> quick-up incomplete — full recover path"
PAAS_FORCE_KYVERNO_UNBLOCK="${PAAS_FORCE_KYVERNO_UNBLOCK:-1}" bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard || true

POSTGRES_UP=0
if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  if kubectl wait --for=condition=available deployment/postgres -n "${PAAS_NS}" --timeout=30s 2>/dev/null; then
    POSTGRES_UP=1
  fi
fi

if [[ "${POSTGRES_UP}" -eq 1 ]]; then
  echo "==> Postgres up — db-repair (non-destructive; keeps Service/endpoints)"
  PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
else
  echo "==> Hold frontend until Postgres is up (prevents Prisma login errors on reboot)"
  if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
    kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
  fi
  echo "==> Postgres in namespace ${PAAS_NS} (PVC keeps users/projects)"
  bash "${SCRIPT_DIR}/lab-postgres.sh" deploy
  bash "${SCRIPT_DIR}/lab-postgres.sh" wait
fi

if kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='User'" 2>/dev/null | grep -q 1; then
  echo "schema ok"
else
  bash "${SCRIPT_DIR}/lab-postgres.sh" schema
fi

if [[ -f "${ENV_FILE}" ]]; then
  PAAS_SKIP_ROLLOUT=1 ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || {
    echo "WARN: env sync failed — starting frontend with existing deployment env" >&2
  }
else
  kubectl set env deployment/frontend -n "${PAAS_NS}" \
    DATABASE_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'
fi

echo "==> Kyverno require-non-root workload patches (frontend/postgres)"
bash "${SCRIPT_DIR}/lab-kyverno.sh" workloads || true

echo "==> Recover frontend on master (recovery image, Recreate, NodePort :30100)"
if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "ERROR: deployment/frontend missing in namespace ${PAAS_NS}" >&2
  exit 1
fi
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false 2>/dev/null || true
bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh"

HEALTH_OK=0
for i in $(seq 1 12); do
  if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
    HEALTH_OK=1
    break
  fi
  echo "health check ${i}/12 failed (UI may still be rolling out); retry in 15s…"
  sleep 15
done

if [[ "${HEALTH_OK}" -ne 1 ]]; then
  echo "recover finished but health check still failing"
  diagnose_frontend
  exit 1
fi

echo "OK — PaaS health passed"

# Boot service must stop here — Harbor bootstrap restarts k3s and needs interactive sudo.
if [[ "${PAAS_BOOT_RECOVER:-0}" == "1" ]]; then
  bash "${SCRIPT_DIR}/lab-guard-cron.sh" install 2>/dev/null || true
  echo ""
  echo "OK — PaaS login: http://${NODE_IP}:30100/login (boot recover — skipped heavy bootstrap)"
  exit 0
fi

echo "==> Platform bootstrap (Harbor cosign realm + Kyverno policy)"
bash "${SCRIPT_DIR}/lab-kyverno.sh" bootstrap || true
if [[ -f "${ENV_FILE}" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true
  bash "${SCRIPT_DIR}/sync-jenkins-pipeline-from-repo.sh" || true
fi

echo "==> Lab guard (images, Prometheus, stale pods)"
bash "${SCRIPT_DIR}/lab-guard.sh" || echo "WARN: lab-guard reported issues — run: bash paas/scripts/lab.sh guard"

echo "==> Install auto-heal cron (watchdog + guard)"
bash "${SCRIPT_DIR}/lab-guard-cron.sh" install || echo "WARN: could not install cron — run: bash paas/scripts/lab.sh harden"

echo ""
echo "OK — PaaS login: http://${NODE_IP}:30100/login"
