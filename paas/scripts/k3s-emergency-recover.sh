#!/usr/bin/env bash
# Emergency k3s recovery — loud output, timeouts, log file (when kubectl/scripts hang).
# Run: sudo bash paas/scripts/k3s-emergency-recover.sh
exec > >(tee -a /tmp/k3s-emergency.log) 2>&1
set -x
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

echo "=============================================="
echo " k3s emergency recover  $(date)"
echo " log: /tmp/k3s-emergency.log"
echo "=============================================="

df -h / /var/lib/rancher 2>/dev/null || df -h /
free -h
swapon --show 2>/dev/null || echo "no swap"

echo "==> stop lab timers + k3s"
timeout 30 systemctl stop paas-lab-start-retry.timer paas-lab-start-retry2.timer paas-lab-start-retry3.timer 2>/dev/null || true
timeout 30 systemctl stop paas-lab-start.service 2>/dev/null || true
timeout 60 systemctl stop k3s 2>/dev/null || true
sleep 8

echo "==> killall"
if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
  timeout 120 /usr/local/bin/k3s-killall.sh || true
else
  timeout 10 pkill -9 k3s 2>/dev/null || true
fi
sleep 8

if ! swapon --show 2>/dev/null | grep -q .; then
  echo "==> add 2G swap (8GB lab)"
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
  fi
  swapon /swapfile 2>/dev/null || true
  free -h
fi

echo "==> start k3s"
systemctl reset-failed k3s 2>/dev/null || true
systemctl start k3s
echo "sleep 120s..."
sleep 120

echo "==> API test (20s max — will NOT hang)"
if timeout 20 k3s kubectl get nodes --request-timeout=15s; then
  echo "OK: k3s API up"
  k3s kubectl get nodes -o wide
  echo ""
  echo "Next: cd ~/devsecops_paas_miscroservices && git fetch origin && git reset --hard origin/main"
  echo "      bash paas/scripts/lab.sh quick-up"
  exit 0
fi

echo "FAIL: API still down"
ss -lntp 2>/dev/null | grep 6443 || echo "6443 not listening"
journalctl -u k3s -n 25 --no-pager 2>/dev/null || true
dmesg -T 2>/dev/null | grep -iE 'oom|killed process' | tail -5 || true
echo ""
echo "Try: sudo reboot   (wait 3 min after VM comes back, run this script again)"
exit 1
