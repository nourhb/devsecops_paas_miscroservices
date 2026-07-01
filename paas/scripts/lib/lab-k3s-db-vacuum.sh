#!/usr/bin/env bash
# Fix k3s stuck in "activating" — slow kine/SQLite (compact_rev_key queries).
set -uo pipefail

DB_DIR="/var/lib/rancher/k3s/server/db"
STATE_DB="${DB_DIR}/state.db"

log() { echo "[k3s-vacuum] $*"; }
die() { log "ERROR: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "run with sudo: sudo bash paas/scripts/lab.sh k3s-vacuum"

log "stop k3s + boot timers (no more API load)"
systemctl stop paas-lab-start-retry.timer paas-lab-start-retry2.timer paas-lab-start-retry3.timer 2>/dev/null || true
systemctl stop paas-lab-start.service 2>/dev/null || true
systemctl stop k3s 2>/dev/null || true
sleep 10
if pgrep -x k3s >/dev/null 2>&1; then
  log "k3s still running — waiting 30s"
  sleep 30
  systemctl kill k3s 2>/dev/null || true
  sleep 5
fi

[[ -f "${STATE_DB}" ]] || die "no ${STATE_DB} — is k3s installed?"

BACKUP="/var/lib/rancher/k3s/server/db.backup-$(date +%Y%m%d%H%M%S)"
log "backup db -> ${BACKUP}"
cp -a "${DB_DIR}" "${BACKUP}"

BEFORE="$(du -sh "${STATE_DB}" | awk '{print $1}')"
log "state.db size before: ${BEFORE}"

if ! command -v sqlite3 >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y sqlite3
fi

log "VACUUM SQLite (can take 5–45 min on bloated db — progress every 30s)"
sqlite3 "${STATE_DB}" "VACUUM;" &
vac_pid=$!
while kill -0 "${vac_pid}" 2>/dev/null; do
  echo "  …VACUUM running $(date +%H:%M:%S) — state.db ${BEFORE}"
  sleep 30
done
wait "${vac_pid}" || die "VACUUM failed"
sqlite3 "${STATE_DB}" "PRAGMA optimize;"

AFTER="$(du -sh "${STATE_DB}" | awk '{print $1}')"
log "state.db size after: ${AFTER}"

log "start k3s — wait for API (systemd may stay 'activating' while API is up)"
systemctl start k3s
sleep 20

api_up() {
  timeout 15 k3s kubectl get --raw=/healthz --request-timeout=12s >/dev/null 2>&1 \
    || timeout 15 k3s kubectl get nodes --request-timeout=12s >/dev/null 2>&1
}

for i in $(seq 1 90); do
  if api_up; then
    log "OK: k3s API up (attempt ${i}/90, systemd=$(systemctl is-active k3s 2>/dev/null || echo ?))"
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

log "API still down — try hard unstick: sudo bash paas/scripts/lab.sh k3s-unstick"
journalctl -u k3s -n 30 --no-pager 2>/dev/null | tail -30 || true
exit 1
