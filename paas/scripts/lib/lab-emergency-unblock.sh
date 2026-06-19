#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " lab-emergency-unblock — Kyverno + disk + nodes"
echo "=============================================="

kyverno_up() {
  kubectl get endpoints -n kyverno kyverno-svc -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

echo "==> Disk (master) — quick cleanup only (no cluster-wide image pulls)"
df -h / /var/lib/rancher 2>/dev/null || df -h /
PAAS_DISK_QUICK=1 bash "${SCRIPT_DIR}/lab-monitoring-disk-heal.sh" quick 2>/dev/null || true
sudo journalctl --vacuum-size=200M 2>/dev/null || true

if ! kyverno_up; then
  bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard || true
else
  echo "OK: kyverno admission service up"
fi

echo "==> Node scheduling"
kubectl taint nodes master node.kubernetes.io/disk-pressure:NoSchedule- 2>/dev/null || true
kubectl uncordon master 2>/dev/null || true
kubectl uncordon worker1 2>/dev/null || true
kubectl get nodes -o wide

echo "==> Restart Kyverno (after disk / webhook unblock)"
if kubectl get ns kyverno >/dev/null 2>&1; then
  kubectl rollout restart deployment/kyverno-admission-controller -n kyverno 2>/dev/null || true
  kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=180s 2>/dev/null || true
fi

if [[ -f "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" ]]; then
  COSIGN_LAB_ENFORCE_SIGNED=false bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" 2>/dev/null || true
fi

echo "==> Postgres + frontend"
PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" 2>/dev/null || {
  kubectl rollout restart deployment/postgres -n "${PAAS_NS}" 2>/dev/null || true
  kubectl wait --for=condition=available deployment/postgres -n "${PAAS_NS}" --timeout=300s 2>/dev/null || true
}

bash "${SCRIPT_DIR}/lab-frontend-schedule-heal.sh" || true

echo "=============================================="
echo "If worker2 stays NotReady: ssh worker2 && sudo systemctl restart k3s-agent"
echo "PaaS UI: http://${NODE_IP}:30100/login"
echo "=============================================="
