#!/usr/bin/env bash
# k3s systemd stuck in "activating" — hard stop, killall, API-based wait (not systemd active).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

log() { echo "[k3s-unstick] $(date +%H:%M:%S) $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run with sudo: sudo bash paas/scripts/lab.sh k3s-unstick"

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo 0)"
MEM_AVAIL="$(free -m 2>/dev/null | awk '/Mem:/ {print $7}' || echo 0)"
log "disk=${DISK_PCT}% mem_available=${MEM_AVAIL}MB"
df -h / /var/lib/rancher 2>/dev/null | tail -n +2 || true
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 92 ]]; then
  die "disk ${DISK_PCT}% full — free space first: bash paas/scripts/lab.sh disk-emergency"
fi
if [[ -n "${MEM_AVAIL}" && "${MEM_AVAIL}" -lt 400 ]]; then
  log "WARN: low memory (${MEM_AVAIL}MB) — k3s may stay activating until RAM frees"
fi

log "stop boot timers + k3s"
systemctl stop paas-lab-start-retry.timer paas-lab-start-retry2.timer paas-lab-start-retry3.timer 2>/dev/null || true
systemctl stop paas-lab-start.service 2>/dev/null || true
systemctl stop k3s 2>/dev/null || true
sleep 12

if pgrep -x k3s >/dev/null 2>&1; then
  log "k3s processes still running — kill"
  systemctl kill -s SIGKILL k3s 2>/dev/null || true
  sleep 5
  pkill -9 -x k3s 2>/dev/null || true
  sleep 3
fi

if [[ -x /usr/local/bin/k3s-killall.sh ]]; then
  log "k3s-killall.sh (containerd + leftovers)"
  /usr/local/bin/k3s-killall.sh 2>/dev/null || true
  sleep 5
fi

log "reset failed state"
systemctl reset-failed k3s 2>/dev/null || true

log "last k3s errors before restart:"
journalctl -u k3s -n 20 --no-pager 2>/dev/null | tail -20 || true

log "start k3s — wait for API (up to 15 min; systemd may stay 'activating')"
systemctl start k3s
sleep 20

api_up() {
  timeout 15 k3s kubectl get --raw=/healthz --request-timeout=12s >/dev/null 2>&1 \
    || timeout 15 k3s kubectl get nodes --request-timeout=12s >/dev/null 2>&1
}

for i in $(seq 1 90); do
  if api_up; then
    log "OK: k3s API responding (attempt ${i}/90, systemd=$(systemctl is-active k3s 2>/dev/null || echo ?))"
    k3s kubectl get nodes -o wide 2>/dev/null || true
    echo ""
    echo "Next: bash paas/scripts/lab.sh quick-up"
    exit 0
  fi
  st="$(systemctl is-active k3s 2>/dev/null || echo unknown)"
  echo "  …${i}/90 API down systemd=${st}"
  if (( i % 6 == 0 )); then
    journalctl -u k3s -n 6 --no-pager 2>/dev/null | tail -6 || true
  fi
  sleep 10
done

log "API still down after 15 min"
journalctl -u k3s -n 40 --no-pager 2>/dev/null | tail -40 || true
echo ""
echo "Paste the journal lines above. Also try:"
echo "  df -h && free -h"
echo "  bash paas/scripts/lab.sh disk-emergency"
exit 1
