#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"
WORKER="${LAB_WORKER_NODE:-worker2}"
WORKER_IP="${LAB_WORKER2_IP:-192.168.56.130}"

echo "=============================================="
echo " lab-worker2-heal — Postgres PVC lives on ${WORKER}"
echo "=============================================="

echo "==> Node status"
kubectl get nodes -o wide
kubectl describe node "${WORKER}" 2>/dev/null | grep -A12 'Conditions:' || true
kubectl describe node "${WORKER}" 2>/dev/null | grep -E 'Taints|MemoryPressure|DiskPressure|PIDPressure' || true

echo "==> Postgres scheduling"
kubectl get pods -n "${PAAS_NS}" -l app=postgres -o wide
kubectl get pvc postgres-pvc -n "${PAAS_NS}" -o wide
PV="$(kubectl get pvc postgres-pvc -n "${PAAS_NS}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
if [[ -n "${PV}" ]]; then
  echo "==> PV ${PV} (local-path is node-bound)"
  kubectl get pv "${PV}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null \
    | xargs -I{} echo "bound node: {}" || kubectl get pv "${PV}" -o yaml | grep -A6 nodeAffinity || true
fi

echo "==> SSH restart k3s-agent on ${WORKER} (${WORKER_IP})"
if ssh -o ConnectTimeout=8 -o BatchMode=yes "${WORKER}" 'echo OK' 2>/dev/null; then
  ssh "${WORKER}" 'sudo systemctl restart k3s-agent; sleep 5; sudo systemctl is-active k3s-agent; df -h / | tail -1; free -h | head -2'
else
  echo "WARN: passwordless ssh to ${WORKER} failed — run manually on worker2:"
  echo "  ssh ${WORKER}"
  echo "  sudo systemctl restart k3s-agent"
  echo "  sudo journalctl -u k3s-agent -n 40 --no-pager"
  echo "  df -h / && free -h"
fi

echo "==> Wait for ${WORKER} Ready (max 3 min)"
for i in $(seq 1 36); do
  STATUS="$(kubectl get node "${WORKER}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
  if [[ "${STATUS}" == "True" ]]; then
    echo "OK: ${WORKER} Ready"
    break
  fi
  sleep 5
  [[ "${i}" -eq 36 ]] && {
    echo "ERROR: ${WORKER} still NotReady — Postgres cannot start (PVC is on this node)." >&2
    kubectl describe node "${WORKER}" | tail -25
    exit 1
  }
done

echo "==> Recycle postgres pod"
kubectl delete pod -n "${PAAS_NS}" -l app=postgres --force --grace-period=0 --wait=false 2>/dev/null || true
kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=300s
kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=180s
kubectl get endpoints postgres -n "${PAAS_NS}"
kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas
echo "OK: postgres up on ${WORKER}"
