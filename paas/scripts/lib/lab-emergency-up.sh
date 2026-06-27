#!/usr/bin/env bash
# Minimal recovery when everything is stuck — no git pull required.
set -uo pipefail
REPO="${HOME}/devsecops_paas_miscroservices"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_NS="${PAAS_NS:-paas}"

echo "=============================================="
echo " lab-emergency-up — unstuck PaaS lab"
echo " $(date -Is 2>/dev/null || date)"
echo "=============================================="

echo "==> 1/6 Stop stuck lab processes + boot timers"
pkill -f "lab-boot-fix|recover-paas|paas-boot-start" 2>/dev/null || true
sudo systemctl stop paas-lab-start-retry.timer 2>/dev/null || true
sudo systemctl stop paas-lab-start.service 2>/dev/null || true
sudo systemctl reset-failed paas-lab-start.service 2>/dev/null || true

echo "==> 2/6 Kyverno fail-open (dead webhooks block kubectl patch)"
export PAAS_FORCE_KYVERNO_UNBLOCK=1
if [[ -f "${REPO}/paas/scripts/lib/lab-kyverno-webhook-guard.sh" ]]; then
  bash "${REPO}/paas/scripts/lib/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true
fi

echo "==> 3/6 kubeconfig"
mkdir -p "${HOME}/.kube"
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  if ! cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config" 2>/dev/null; then
    sudo cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
    sudo chown "${USER}:${USER}" "${HOME}/.kube/config"
  fi
  chmod 600 "${HOME}/.kube/config" 2>/dev/null || true
fi
export KUBECONFIG="${HOME}/.kube/config"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

echo "==> 4/6 Restart k3s (hard reset)"
sudo systemctl restart k3s
for i in $(seq 1 24); do
  if k3s kubectl get nodes >/dev/null 2>&1; then
    echo "OK: k3s API up (attempt ${i})"
    k3s kubectl get nodes 2>/dev/null || true
    break
  fi
  echo "  [${i}/24] waiting for k3s…"
  sleep 5
  if [[ "${i}" -eq 24 ]]; then
    echo "ERROR: k3s still down" >&2
    sudo systemctl status k3s --no-pager | head -20 || true
    echo "Try: df -h /  (disk full?)  sudo journalctl -u k3s -n 30" >&2
    exit 1
  fi
done

echo "==> 5/6 Quick PaaS check"
if k3s kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  FE_READY="$(k3s kubectl get pods -n "${PAAS_NS}" -l app=frontend \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
  PG_READY="$(k3s kubectl get pods -n "${PAAS_NS}" -l app=postgres \
    -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null || echo False)"
  echo "  frontend ready=${FE_READY}  postgres=${PG_READY}"
  if [[ "${FE_READY}" == "true" && "${PG_READY}" == "True" ]]; then
    HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
    if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
      echo "OK: UI already up HTTP ${HTTP} — skip heavy recover"
      echo ""
      echo "=============================================="
      echo " PaaS: http://${NODE_IP}:30100/login"
      echo "=============================================="
      exit 0
    fi
  fi
fi

echo "==> 6/6 Run lab recover (frontend-force path)"
if [[ -x "${REPO}/paas/scripts/lab.sh" ]]; then
  cd "${REPO}"
  chmod +x paas/scripts/lab.sh paas/scripts/lib/*.sh 2>/dev/null || true
  PAAS_FORCE_KYVERNO_UNBLOCK=1 bash paas/scripts/lab.sh start || {
    echo "WARN: lab.sh start failed — trying frontend-force only"
    PAAS_FORCE_KYVERNO_UNBLOCK=1 bash paas/scripts/lab.sh frontend-force || true
  }
  bash paas/scripts/lab.sh health 2>/dev/null || true
else
  echo "ERROR: ${REPO}/paas/scripts/lab.sh missing" >&2
  exit 1
fi

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
echo ""
if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
  echo "=============================================="
  echo " OK — PaaS: http://${NODE_IP}:30100/login  (HTTP ${HTTP})"
  echo "=============================================="
  exit 0
fi

echo "WARN: UI HTTP ${HTTP} — check:"
echo "  k3s kubectl get pods -n paas"
echo "  k3s kubectl logs -n paas deploy/frontend --tail=40"
exit 1
