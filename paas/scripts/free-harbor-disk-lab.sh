#!/usr/bin/env bash
# Free space for Harbor on lab (registry PVC + node root). 502 on blob upload when disk ~full.
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
HARBOR_NS="${HARBOR_NS:-harbor}"

echo "==> Registry pod disk"
kubectl exec -n "${HARBOR_NS}" deploy/harbor-registry -c registry -- df -h /storage 2>/dev/null \
  || kubectl exec -n "${HARBOR_NS}" deploy/harbor-registry -c registry -- df -h / 2>/dev/null \
  || echo "WARN: could not df harbor-registry"

echo ""
echo "==> Host root (master)"
df -h / | tail -1

echo ""
echo "==> Prune completed/failed pods (cluster)"
kubectl delete pods -A --field-selector=status.phase=Failed --ignore-not-found 2>/dev/null || true
kubectl delete pods -A --field-selector=status.phase=Succeeded --ignore-not-found 2>/dev/null || true

echo ""
echo "==> Docker prune on this node (master)"
if command -v docker >/dev/null 2>&1; then
  docker system prune -af --volumes 2>/dev/null || docker system prune -af 2>/dev/null || true
fi

echo ""
echo "==> Harbor garbage collection (API)"
if curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${HARBOR}/api/v2.0/ping" 2>/dev/null | grep -q 200; then
  gc="$(curl -sS -u "${HARBOR_USER}:${HARBOR_PASS}" -X POST \
    "http://${HARBOR}/api/v2.0/system/gc" 2>/dev/null || true)"
  if [[ -n "${gc}" ]]; then
    echo "GC triggered: ${gc:0:120}"
  else
    echo "WARN: GC POST failed (Harbor UI → Administration → Garbage Collection)"
  fi
else
  echo "WARN: Harbor API not up — skip GC"
fi

echo ""
echo "==> After cleanup"
kubectl exec -n "${HARBOR_NS}" deploy/harbor-registry -c registry -- df -h /storage 2>/dev/null \
  || kubectl exec -n "${HARBOR_NS}" deploy/harbor-registry -c registry -- df -h / 2>/dev/null || true
df -h / | tail -1
echo ""
echo "==> worker2 (Harbor node) — prune container images"
WORKER_NODE="${WORKER2_NODE:-worker2}"
WORKER_IP="$(kubectl get node "${WORKER_NODE}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
WORKER_HOST="${WORKER2_SSH:-}"
if [[ -z "${WORKER_HOST}" && -n "${WORKER_IP}" ]]; then
  WORKER_HOST="${WORKER_IP}"
fi
if [[ -n "${WORKER_HOST}" ]] && command -v ssh >/dev/null 2>&1; then
  echo "Pruning via ssh ${WORKER_HOST} (node ${WORKER_NODE})…"
  ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
    "${WORKER2_USER:-master}@${WORKER_HOST}" \
    "docker system prune -af 2>/dev/null; sudo crictl rmi --prune 2>/dev/null; df -h / | tail -1" 2>/dev/null \
    || echo "WARN: ssh to ${WORKER_HOST} failed — use: WORKER2_SSH=<ip> bash paas/scripts/free-harbor-disk-lab.sh"
else
  echo "WARN: set WORKER2_SSH=192.168.56.x (worker2 IP from: kubectl get nodes -o wide)"
  echo "  docker system prune -af && sudo crictl rmi --prune && df -h /"
fi
