#!/usr/bin/env bash
# Force one frontend pod on master when rollout/describe hang (evicted-pod API storm).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
IMG="${IMG:-docker.io/library/paas-frontend:recovery}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " lab-frontend-force-recover"
echo "=============================================="
df -h / | tail -1

image_on_node() {
  sudo k3s crictl images 2>/dev/null | grep -qE 'paas-frontend.*recovery' \
    || sudo k3s ctr -n k8s.io images ls 2>/dev/null | grep -qF 'paas-frontend:recovery'
}

import_recovery_image() {
  local src="" candidate
  for candidate in "${IMG}" "paas-frontend:recovery" "docker.io/library/paas-frontend:recovery"; do
    if docker image inspect "${candidate}" >/dev/null 2>&1; then
      src="${candidate}"
      break
    fi
  done
  if [[ -z "${src}" ]]; then
    echo "ERROR: paas-frontend:recovery not in docker — rebuild on master:" >&2
    echo "  docker images | grep paas-frontend" >&2
    echo "  # or: bash paas/scripts/lab.sh frontend  (long build)" >&2
    return 1
  fi
  echo "==> Import ${src} into k3s containerd (fixes ErrImageNeverPull)"
  docker save "${src}" | sudo k3s ctr -n k8s.io images import - 2>/dev/null
  sudo k3s ctr -n k8s.io images tag "${src}" "${IMG}" 2>/dev/null || true
  sudo k3s ctr -n k8s.io images tag "${src}" "paas-frontend:recovery" 2>/dev/null || true
  sudo k3s crictl images 2>/dev/null | grep paas-frontend || true
}

echo "==> Image on master (before any slow kubectl work)"
if ! image_on_node; then
  import_recovery_image || exit 1
else
  echo "OK: recovery image already in containerd"
  sudo k3s crictl images 2>/dev/null | grep paas-frontend || true
fi

PAAS_SKIP_KYVERNO_RESTART=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true

postgres_ready_quick() {
  kubectl get endpoints postgres -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

wait_postgres_ready() {
  echo "==> Wait for postgres Service + pg_isready (max 3 min)"
  for i in $(seq 1 36); do
    if postgres_ready_quick && kubectl exec -n "${PAAS_NS}" deploy/postgres --request-timeout=20s -- \
        pg_isready -U postgres -d paas >/dev/null 2>&1; then
      echo "OK: postgres ready (${i}/36)"
      kubectl get endpoints postgres -n "${PAAS_NS}" -o wide 2>/dev/null || true
      return 0
    fi
    echo "  [${i}/36] postgres not ready yet"
    if (( i % 6 == 0 )) && ! postgres_ready_quick; then
      echo "==> Still no endpoints — db-repair (once)"
      PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
    fi
    sleep 5
  done
  echo "ERROR: postgres not ready — try:" >&2
  echo "  bash paas/scripts/lab.sh worker2   # PVC is on worker2" >&2
  echo "  PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash paas/scripts/lab.sh db-repair" >&2
  return 1
}

echo "==> Postgres preflight (frontend on master must reach postgres Service)"
if ! wait_postgres_ready; then
  bash "${SCRIPT_DIR}/lab-worker2-heal.sh" 2>/dev/null || true
  wait_postgres_ready || exit 1
fi

echo "==> Scale frontend to 0 + drop old ReplicaSets"
set +e
kubectl rollout resume deployment/frontend -n "${PAAS_NS}" --request-timeout=30s 2>/dev/null
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 --request-timeout=45s 2>/dev/null
kubectl get rs -n "${PAAS_NS}" -l app=frontend -o name --request-timeout=45s 2>/dev/null \
  | xargs -r kubectl delete --request-timeout=45s --wait=false 2>/dev/null
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false \
  --request-timeout=30s 2>/dev/null

echo "==> Chunk-delete Failed pods in ${PAAS_NS} (max 20 batches; API timeouts OK)"
for _ in $(seq 1 20); do
  batch="$(kubectl get pods -n "${PAAS_NS}" --field-selector=status.phase=Failed -o name \
    --request-timeout=25s 2>/dev/null | head -150)" || batch=""
  [[ -z "${batch}" ]] && break
  echo "${batch}" | xargs -r kubectl delete --request-timeout=45s --force --grace-period=0 --wait=false \
    2>/dev/null || true
  sleep 1
done
set -e

echo "==> Patch deployment (Recreate, master, Never pull)"
kubectl patch deployment frontend -n "${PAAS_NS}" --type=merge --request-timeout=60s -p "$(cat <<PATCH
{
  "spec": {
    "revisionHistoryLimit": 0,
    "replicas": 1,
    "strategy": {"type": "Recreate"},
    "template": {
      "spec": {
        "nodeSelector": {"kubernetes.io/hostname": "master"},
        "tolerations": [{
          "key": "node.kubernetes.io/disk-pressure",
          "operator": "Exists",
          "effect": "NoSchedule"
        }],
        "serviceAccountName": "paas-frontend",
        "initContainers": [{
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
        }],
        "containers": [{
          "name": "frontend",
          "image": "${IMG}",
          "imagePullPolicy": "Never",
          "envFrom": [{"secretRef": {"name": "paas-frontend-env"}}],
          "env": [{"name": "DATABASE_URL", "value": "${DB_URL}"}]
        }]
      }
    }
  }
}
PATCH
)" || exit 1

echo "==> Wait for Running pod"
for i in $(seq 1 48); do
  set +e
  reason="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend \
    --field-selector=status.phase!=Failed \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' \
    --request-timeout=20s 2>/dev/null)" || reason=""
  ready="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' \
    --request-timeout=20s 2>/dev/null)" || ready=""
  phase="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend \
    --field-selector=status.phase!=Failed \
    -o jsonpath='{.items[0].status.phase}' --request-timeout=20s 2>/dev/null)" || phase=""
  set -e
  echo "  [${i}/48] phase=${phase:-none} ready=${ready:-false} reason=${reason:-}"
  if [[ "${reason}" == "ErrImageNeverPull" ]]; then
    echo "==> ErrImageNeverPull — re-import image and delete pod"
    import_recovery_image || true
    kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false \
      --request-timeout=30s 2>/dev/null || true
  fi
  [[ "${ready}" == "true" ]] && break
  sleep 5
done

kubectl get pods -n "${PAAS_NS}" -l app=frontend \
  --field-selector=status.phase!=Failed -o wide --request-timeout=30s 2>/dev/null || true

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30100/api/health" 2>/dev/null || echo 000)"
echo "api/health HTTP ${HTTP}"
DB_JSON="$(curl -sS --connect-timeout 8 "http://${NODE_IP}:30100/api/health" 2>/dev/null || echo '{}')"
echo "${DB_JSON}" | grep -o '"connected":[^,}]*' || true

frontend_tcp_probe() {
  kubectl exec -n "${PAAS_NS}" deploy/frontend --request-timeout=45s -- node -e "
const net=require('net');
const s=net.connect(5432,'postgres');
s.on('connect',()=>{console.log('OK');process.exit(0)});
s.on('error',(e)=>{console.error(e.message||e);process.exit(1)});
setTimeout(()=>{console.error('timeout');process.exit(1)},8000);
" 2>/dev/null
}

if [[ "${HTTP}" == "200" ]] && frontend_tcp_probe | grep -q '^OK$'; then
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true
else
  if ! frontend_tcp_probe | grep -q '^OK$'; then
    echo "==> Frontend cannot TCP postgres:5432 — db-repair"
    PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
    HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30100/api/health" 2>/dev/null || echo 000)"
    echo "api/health HTTP ${HTTP} (after db-repair)"
  fi
  echo "Note: api/health 503 with database.connected=true is OK (ArgoCD optional in lab)."
  echo "If login shows DB unavailable: PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash paas/scripts/lab.sh db-repair"
  echo "If postgres PVC node down: bash paas/scripts/lab.sh worker2"
  echo "If HTTP 500 (env): bash paas/scripts/lab.sh env-quick"
  echo "If ErrImageNeverPull: docker images | grep paas-frontend  then re-run this script"
  echo "If Evicted: free disk below 88% then re-run"
fi
