#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MANIFEST="${PAAS_DIR}/k8s-manifests/lab/postgres-in-paas.yaml"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'
COOLDOWN_SEC="${PAAS_DB_REPAIR_COOLDOWN_SEC:-900}"
STATE_FILE="/var/tmp/paas-lab-db-repair.ts"
LOCK_FILE="/var/tmp/paas-lab-db-repair.lock"

auto_heal_blocked() {
  [[ -f /var/tmp/paas-lab-no-auto-heal ]]
}

cooldown_active() {
  [[ -f "${STATE_FILE}" ]] || return 1
  local last now
  last="$(cat "${STATE_FILE}" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last < COOLDOWN_SEC ))
}

mark_repair() {
  date +%s > "${STATE_FILE}" 2>/dev/null || sudo sh -c "date +%s > ${STATE_FILE}" 2>/dev/null || true
}

postgres_endpoints_up() {
  kubectl get endpoints postgres -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

postgres_pg_isready() {
  kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1
}

frontend_tcp_probe() {
  kubectl exec -n "${PAAS_NS}" deploy/frontend -- node -e "
const net=require('net');
const host=process.env.PG_HOST||'postgres';
const port=Number(process.env.PG_PORT||5432);
const s=net.connect(port,host);
s.on('connect',()=>{console.log('OK');process.exit(0)});
s.on('error',(e)=>{console.error(e.message||e);process.exit(1)});
setTimeout(()=>{console.error('timeout');process.exit(1)},8000);
" 2>/dev/null
}

patch_frontend_wait_postgres() {
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p "$(cat <<'PATCH'
{
  "spec": {
    "template": {
      "spec": {
        "initContainers": [
          {
            "name": "wait-postgres",
            "image": "busybox:1.36",
            "command": [
              "sh",
              "-c",
              "until nc -z postgres 5432; do echo waiting for postgres; sleep 3; done"
            ],
            "securityContext": {
              "runAsNonRoot": true,
              "runAsUser": 1001,
              "allowPrivilegeEscalation": false
            }
          }
        ]
      }
    }
  }
}
PATCH
)" 2>/dev/null || true
}

if auto_heal_blocked; then
  echo "SKIP: auto-heal paused (/var/tmp/paas-lab-no-auto-heal) — run: rm /var/tmp/paas-lab-no-auto-heal"
  exit 0
fi

if cooldown_active; then
  echo "SKIP: db-repair cooldown (${COOLDOWN_SEC}s) — postgres restart loop prevented"
  echo "      Force: PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash paas/scripts/lab.sh db-repair"
  exit 0
fi

exec 9>"${LOCK_FILE}" 2>/dev/null || exec 9>/tmp/paas-lab-db-repair.lock
if ! flock -n 9 2>/dev/null; then
  echo "SKIP: another db-repair is running"
  exit 0
fi

mark_repair

echo "==> Apply Postgres manifest (listen_addresses=*)"
kubectl apply -f "${MANIFEST}"
echo "==> Postgres endpoints"
kubectl get endpoints postgres -n "${PAAS_NS}" -o wide 2>/dev/null || true

PG_NEEDS_RESTART=1
if postgres_endpoints_up && postgres_pg_isready; then
  echo "OK: postgres already up — skip restart"
  PG_NEEDS_RESTART=0
fi

if [[ "${PG_NEEDS_RESTART}" -eq 1 ]]; then
  echo "==> Rollout restart postgres (once)"
  kubectl rollout restart deployment/postgres -n "${PAAS_NS}" || true
  if ! kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=180s; then
    echo "WARN: postgres rollout slow — diagnostics (not restarting again):" >&2
    kubectl get pods -n "${PAAS_NS}" -l app=postgres -o wide || true
    kubectl describe pod -n "${PAAS_NS}" -l app=postgres | tail -35 || true
    kubectl get pvc postgres-pvc -n "${PAAS_NS}" -o wide 2>/dev/null || true
    echo "Fix root cause, then: PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash paas/scripts/lab.sh db-repair" >&2
    exit 1
  fi
  kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s
fi

echo "==> Ensure frontend DATABASE_URL uses in-cluster service postgres:5432"
kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" --containers=frontend 2>/dev/null \
  || kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" || true
patch_frontend_wait_postgres

if frontend_tcp_probe | grep -q '^OK$'; then
  echo "OK: frontend pod TCP -> postgres:5432"
  exit 0
fi

FR="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
if [[ "${FR}" == "0" ]]; then
  echo "WARN: frontend scaled to 0 — not restarting (run frontend-heal when postgres stable)"
  exit 1
fi

echo "WARN: TCP probe failed — one frontend restart only"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
if ! kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s; then
  echo "WARN: frontend rollout slow — check: kubectl get pods -n ${PAAS_NS} -l app=frontend" >&2
  exit 1
fi
if frontend_tcp_probe | grep -q '^OK$'; then
  echo "OK: frontend pod TCP -> postgres:5432 after restart"
  exit 0
fi
echo "ERROR: frontend still cannot reach postgres:5432" >&2
kubectl get pods,svc,endpoints -n "${PAAS_NS}" | grep -E 'postgres|frontend|NAME' || true
kubectl logs -n "${PAAS_NS}" -l app=postgres --tail=30 2>/dev/null || true
exit 1
