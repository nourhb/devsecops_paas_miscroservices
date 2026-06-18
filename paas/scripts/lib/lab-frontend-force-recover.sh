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

PAAS_SKIP_KYVERNO_RESTART=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true

echo "==> Scale frontend to 0 + drop old ReplicaSets (speeds API)"
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 --request-timeout=45s 2>/dev/null || true
kubectl rollout pause deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl get rs -n "${PAAS_NS}" -l app=frontend -o name --request-timeout=45s 2>/dev/null \
  | xargs -r kubectl delete --request-timeout=45s --wait=false 2>/dev/null || true

echo "==> Chunk-delete Failed pods in ${PAAS_NS} (max 30 batches)"
for _ in $(seq 1 30); do
  batch="$(kubectl get pods -n "${PAAS_NS}" --field-selector=status.phase=Failed -o name \
    --request-timeout=30s 2>/dev/null | head -200)"
  [[ -z "${batch}" ]] && break
  echo "${batch}" | xargs -r kubectl delete --request-timeout=45s --force --grace-period=0 --wait=false \
    2>/dev/null || true
  sleep 1
done

echo "==> Ensure image on master containerd"
if ! sudo k3s ctr -n k8s.io images ls -q 2>/dev/null | grep -qF 'paas-frontend:recovery'; then
  if docker image inspect "${IMG}" >/dev/null 2>&1; then
    docker save "${IMG}" | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
  else
    echo "ERROR: ${IMG} missing from docker and containerd — rebuild on master first" >&2
    exit 1
  fi
fi
sudo k3s ctr -n k8s.io images ls 2>/dev/null | grep paas-frontend || true

echo "==> Patch deployment (Recreate, master, Never pull, revisionHistoryLimit 0)"
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
        "containers": [{
          "name": "frontend",
          "image": "${IMG}",
          "imagePullPolicy": "Never",
          "env": [{"name": "DATABASE_URL", "value": "${DB_URL}"}]
        }]
      }
    }
  }
}
PATCH
)" || exit 1

kubectl rollout resume deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true

echo "==> Wait for Running pod (events — not describe -l app=frontend)"
for i in $(seq 1 60); do
  phase="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend \
    --field-selector=status.phase!=Failed \
    -o jsonpath='{.items[0].status.phase}' --request-timeout=20s 2>/dev/null || true)"
  ready="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' --request-timeout=20s 2>/dev/null || true)"
  echo "  [${i}/60] phase=${phase:-none} ready=${ready:-false}"
  [[ "${ready}" == "true" ]] && break
  if [[ "${phase}" == "Evicted" || "${phase}" == "Failed" ]]; then
    kubectl get events -n "${PAAS_NS}" --sort-by='.lastTimestamp' --request-timeout=20s 2>/dev/null | tail -8 || true
    echo "WARN: pod evicted/failed — disk may still be >= 90%; run: bash paas/scripts/lab.sh disk-emergency"
  fi
  sleep 5
done

kubectl get pods -n "${PAAS_NS}" -l app=frontend \
  --field-selector=status.phase!=Failed -o wide --request-timeout=30s 2>/dev/null || true

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30100/api/health" 2>/dev/null || echo 000)"
echo "api/health HTTP ${HTTP}"
if [[ "${HTTP}" == "200" ]]; then
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true
else
  echo "If still 000: kubectl get endpoints frontend-service -n ${PAAS_NS}"
  echo "If Evicted: free disk below 88% then re-run this script"
fi
