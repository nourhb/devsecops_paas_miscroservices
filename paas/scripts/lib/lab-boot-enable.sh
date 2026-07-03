#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " boot-enable — auto-start PaaS on VM power-on"
echo "=============================================="

cd "${REPO_ROOT}"
chmod +x paas/scripts/lab.sh paas/scripts/lib/*.sh 2>/dev/null || true

export PAAS_FORCE_KYVERNO_UNBLOCK=1
export PAAS_BOOT_RECOVER=1
export PAAS_SKIP_KYVERNO_RESTART=1

echo "==> 1/6 Lab harden (postgres PG15, frontend safety, cron)"
bash paas/scripts/lib/lab-harden.sh || echo "WARN: harden had warnings — continuing"

echo ""
echo "==> 2/6 Kubeconfig for ${USER}"
mkdir -p "${HOME}/.kube"
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  cp -f /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config" 2>/dev/null \
    || sudo install -o "${USER}" -g "${USER}" -m 600 /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config"
  chmod 600 "${HOME}/.kube/config" 2>/dev/null || true
fi
export KUBECONFIG="${HOME}/.kube/config"

echo ""
echo "==> 3/6 Install systemd boot service + retry timers"
if [[ "$(id -u)" -eq 0 ]]; then
  PAAS_REPO_DIR="${REPO_ROOT}" PAAS_LAB_USER="${SUDO_USER:-master}" \
    bash paas/scripts/lib/install-paas-boot-service.sh install
else
  sudo env PAAS_REPO_DIR="${REPO_ROOT}" PAAS_LAB_USER="${USER}" \
    bash paas/scripts/lib/install-paas-boot-service.sh install
fi

echo ""
echo "==> 4/6 Pipeline integrations (Harbor RBAC, Artifactory, ZAP, Jenkins CPS)"
if [[ -f paas/scripts/lib/fix-harbor-push-now.sh ]]; then
  bash paas/scripts/lib/fix-harbor-push-now.sh || echo "WARN: harbor push fix — run manually if Step 6 returns 401"
fi
if [[ -f paas/scripts/lib/lab-enable-full-pipeline.sh ]]; then
  PAAS_SKIP_ROLLOUT=1 bash paas/scripts/lib/lab-enable-full-pipeline.sh || echo "WARN: full-pipeline enable had issues"
fi
if [[ -f paas/scripts/lib/fix-paas-deploy-cps-split-now.sh ]]; then
  bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh || echo "WARN: CPS sync failed — run manually"
fi

echo ""
echo "==> 5/6 Re-enable auto-heal (remove manual pause file if present)"
sudo rm -f /var/tmp/paas-lab-no-auto-heal 2>/dev/null || rm -f /var/tmp/paas-lab-no-auto-heal 2>/dev/null || true

echo ""
echo "==> 6/6 Test boot recover (same as after VM reboot)"
sudo systemctl start paas-lab-start.service

echo ""
echo "==> Waiting for health (up to 15 min)…"
for i in $(seq 1 60); do
  if bash paas/scripts/lab.sh health; then
    echo ""
    echo "=============================================="
    echo " OK — auto-start configured"
    echo ""
    echo " After VM reboot:"
    echo "   wait 5–15 minutes (no SSH required)"
    echo "   open http://${NODE_IP}:30100/login"
    echo ""
    echo " Log: tail -f /var/log/paas-lab-start.log"
    echo " Status: bash paas/scripts/lab.sh boot-status"
    echo "=============================================="
    exit 0
  fi
  echo "  [${i}/60] not ready yet…"
  sleep 15
done

echo ""
echo "WARN: health still failing — check log:"
echo "  tail -80 /var/log/paas-lab-start.log"
bash paas/scripts/lab.sh boot-status 2>/dev/null || sudo systemctl status paas-lab-start.service --no-pager
exit 1
