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

echo "==> Postgres preflight (frontend on master must reach postgres Service)"
if ! postgres_ready_quick; then
  echo "WARN: postgres endpoints empty — running db-repair (once)"
  PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
elif ! kubectl exec -n "${PAAS_NS}" deploy/postgres --request-timeout=30s -- \
    pg_isready -U postgres -d paas >/dev/null 2>&1; then
  echo "WARN: postgres pod not accepting connections — restart once"
  kubectl rollout restart deployment/postgres -n "${PAAS_NS}" --request-timeout=45s 2>/dev/null || true
  kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=180s 2>/dev/null || true
fi
kubectl get endpoints postgres -n "${PAAS_NS}" -o wide 2>/dev/null || true

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
if [[ "${HTTP}" == "200" ]]; then
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true
else
  echo "If HTTP 503/500 + prisma postgres:5432: bash paas/scripts/lab.sh db-repair"
  echo "If HTTP 500 (env): re-attach env secret — bash paas/scripts/lab.sh env-quick"
  echo "If ErrImageNeverPull: docker images | grep paas-frontend  then re-run this script"
  echo "If Evicted: free disk below 88% then re-run"
fi
