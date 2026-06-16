#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MANIFEST="${PAAS_DIR}/k8s-manifests/lab/postgres-in-paas.yaml"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'

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

echo "==> Apply Postgres manifest (listen_addresses=*)"
kubectl apply -f "${MANIFEST}"
echo "==> Postgres endpoints"
kubectl get endpoints postgres -n "${PAAS_NS}" -o wide 2>/dev/null || true
echo "==> Rollout restart postgres"
kubectl rollout restart deployment/postgres -n "${PAAS_NS}" || true
kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=600s
kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=180s
echo "==> Ensure frontend DATABASE_URL uses in-cluster service postgres:5432"
kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" --containers=frontend 2>/dev/null \
  || kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" || true
patch_frontend_wait_postgres
if frontend_tcp_probe | grep -q '^OK$'; then
  echo "OK: frontend pod TCP -> postgres:5432"
  exit 0
fi
echo "WARN: TCP probe failed — restarting frontend"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
if frontend_tcp_probe | grep -q '^OK$'; then
  echo "OK: frontend pod TCP -> postgres:5432 after restart"
  exit 0
fi
echo "ERROR: frontend still cannot reach postgres:5432" >&2
kubectl get pods,svc,endpoints -n "${PAAS_NS}" | grep -E 'postgres|frontend|NAME' || true
kubectl logs -n "${PAAS_NS}" -l app=postgres --tail=30 2>/dev/null || true
exit 1
