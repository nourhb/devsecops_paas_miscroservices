#!/usr/bin/env bash
# Minimal recovery when everything is stuck — no git pull required.
set -uo pipefail
REPO="${HOME}/devsecops_paas_miscroservices"
LIB="${REPO}/paas/scripts/lib"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_NS="${PAAS_NS:-paas}"

echo "=============================================="
echo " lab-emergency-up — unstuck PaaS lab"
echo " $(date -Is 2>/dev/null || date)"
echo "=============================================="

echo "==> 1/7 Stop stuck lab processes + boot timers"
pkill -f "lab-boot-fix|recover-paas|paas-boot-start" 2>/dev/null || true
sudo systemctl stop paas-lab-start-retry.timer 2>/dev/null || true
sudo systemctl stop paas-lab-start.service 2>/dev/null || true
sudo systemctl reset-failed paas-lab-start.service 2>/dev/null || true

echo "==> 2/7 kubeconfig + scripts executable"
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
chmod +x "${REPO}/paas/scripts/lab.sh" "${LIB}"/*.sh 2>/dev/null || true

echo "==> 3/7 Kyverno fail-open (dead webhooks block kubectl patch)"
export PAAS_FORCE_KYVERNO_UNBLOCK=1
[[ -f "${LIB}/lab-kyverno-webhook-guard.sh" ]] && bash "${LIB}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true

echo "==> 4/7 k3s API"
if ! k3s kubectl get nodes >/dev/null 2>&1; then
  echo "WARN: k3s API down — restarting once"
  sudo systemctl restart k3s
  for i in $(seq 1 24); do
    k3s kubectl get nodes >/dev/null 2>&1 && break
    sleep 5
    [[ "${i}" -eq 24 ]] && { echo "ERROR: k3s still down" >&2; exit 1; }
  done
fi
k3s kubectl get nodes 2>/dev/null || true

echo "==> 5/7 Postgres (fixes 'Database is still starting' on login)"
FE_READY="$(k3s kubectl get pods -n "${PAAS_NS}" -l app=frontend \
  -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
PG_READY="$(k3s kubectl get pods -n "${PAAS_NS}" -l app=postgres \
  -o jsonpath='{.items[0].status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null || echo False)"
echo "  frontend ready=${FE_READY}  postgres=${PG_READY}"
k3s kubectl get pods -n "${PAAS_NS}" -l app=postgres -o wide 2>/dev/null || true

if [[ "${PG_READY}" != "True" ]]; then
  [[ -f "${LIB}/lab-worker2-heal.sh" ]] && bash "${LIB}/lab-worker2-heal.sh" 2>/dev/null || true
  PAAS_DB_REPAIR_COOLDOWN_SEC=0 PAAS_FORCE_KYVERNO_UNBLOCK=1 bash "${LIB}/lab-paas-db-repair.sh" || true
  [[ -f "${LIB}/lab-postgres.sh" ]] && bash "${LIB}/lab-postgres.sh" deploy || true
  [[ -f "${LIB}/lab-postgres.sh" ]] && bash "${LIB}/lab-postgres.sh" wait || true
fi

echo "==> 6/7 Frontend (if UI down)"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
if [[ ! "${HTTP}" =~ ^(200|307|308)$ ]] || [[ "${FE_READY}" != "true" ]]; then
  if [[ -f "${REPO}/paas/scripts/lab.sh" ]]; then
    cd "${REPO}"
    PAAS_FORCE_KYVERNO_UNBLOCK=1 bash paas/scripts/lab.sh frontend-force 2>/dev/null || true
  fi
fi

echo "==> 7/7 Health check"
if [[ -f "${REPO}/paas/scripts/lab.sh" ]]; then
  cd "${REPO}"
  bash paas/scripts/lab.sh health || true
fi

API_HEALTH="$(curl -sS --connect-timeout 15 "http://${NODE_IP}:30100/api/health" 2>/dev/null || echo '{}')"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
echo ""
if echo "${API_HEALTH}" | grep -q '"connected":true'; then
  echo "=============================================="
  echo " OK — login ready: http://${NODE_IP}:30100/login"
  echo "=============================================="
  exit 0
fi

if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
  echo "WARN: UI up but DB not connected — run:"
  echo "  bash paas/scripts/lab.sh db-repair"
  echo "  k3s kubectl logs -n paas -l app=postgres --tail=40"
  exit 1
fi

echo "WARN: UI HTTP ${HTTP}"
exit 1
