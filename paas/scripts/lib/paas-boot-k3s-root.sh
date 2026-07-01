#!/usr/bin/env bash
# Run as root from paas-lab-start.service (ExecStartPre=+) — no sudo password needed.
# Waits for k3s on boot; vacuums SQLite if stuck activating; never restarts while activating.
set -uo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

WAIT_LOOPS="${PAAS_BOOT_K3S_WAIT_LOOPS:-90}"
WAIT_SEC="${PAAS_BOOT_K3S_WAIT_SEC:-10}"
VACUUM_AFTER_SEC="${PAAS_BOOT_K3S_VACUUM_AFTER_SEC:-360}"
STATE_DB="/var/lib/rancher/k3s/server/db/state.db"

log() {
  echo "[$(date -Is 2>/dev/null || date)] paas-boot-k3s-root: $*"
}

k3s_api_up() {
  if command -v k3s >/dev/null 2>&1; then
    timeout 45 k3s kubectl get nodes --request-timeout=35s >/dev/null 2>&1 && return 0
    timeout 45 k3s kubectl get --raw=/healthz --request-timeout=35s >/dev/null 2>&1 && return 0
  fi
  return 1
}

k3s_unit_state() {
  systemctl is-active k3s 2>/dev/null || echo inactive
}

k3s_slow_sql_stuck() {
  journalctl -u k3s --since "15 min ago" --no-pager 2>/dev/null \
    | grep -qE 'Slow SQL.*compact_rev_key|compact_rev_key.*Slow SQL'
}

wait_api() {
  local label="$1"
  local i
  for i in $(seq 1 "${WAIT_LOOPS}"); do
    if k3s_api_up; then
      log "OK: k3s API ready (${label}, attempt ${i}/${WAIT_LOOPS})"
      return 0
    fi
    log "  [${i}/${WAIT_LOOPS}] k3s API not ready (${label}, state=$(k3s_unit_state))…"
    sleep "${WAIT_SEC}"
  done
  return 1
}

vacuum_state_db() {
  [[ -f "${STATE_DB}" ]] || { log "no ${STATE_DB}"; return 1; }
  if ! command -v sqlite3 >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y sqlite3 || return 1
  fi
  local backup="/var/lib/rancher/k3s/server/db.backup-boot-$(date +%Y%m%d%H%M%S)"
  log "SQLite vacuum (k3s stopped) — backup ${backup}"
  systemctl stop k3s 2>/dev/null || true
  sleep 15
  if pgrep -x k3s >/dev/null 2>&1; then
    sleep 20
    systemctl kill k3s 2>/dev/null || true
    sleep 5
  fi
  cp -a "$(dirname "${STATE_DB}")" "${backup}"
  local before after
  before="$(du -sh "${STATE_DB}" | awk '{print $1}')"
  log "state.db before: ${before}"
  sqlite3 "${STATE_DB}" "VACUUM;" || return 1
  sqlite3 "${STATE_DB}" "PRAGMA optimize;" || true
  after="$(du -sh "${STATE_DB}" | awk '{print $1}')"
  log "state.db after: ${after}"
  systemctl start k3s || return 1
  sleep 20
  return 0
}

maybe_vacuum_if_stuck() {
  local elapsed="$1"
  [[ "${elapsed}" -ge "${VACUUM_AFTER_SEC}" ]] || return 1
  k3s_slow_sql_stuck || return 1
  log "k3s activating >${VACUUM_AFTER_SEC}s with slow SQLite — auto vacuum"
  vacuum_state_db
}

log "start — ensure k3s API (wait up to $(( WAIT_LOOPS * WAIT_SEC ))s, vacuum if SQLite stuck)"

st="$(k3s_unit_state)"
case "${st}" in
  active|activating)
    log "k3s state=${st} — wait only (no start/restart)"
    ;;
  failed)
    log "k3s failed — reset-failed + start once"
    systemctl reset-failed k3s 2>/dev/null || true
    systemctl start k3s || true
    sleep 20
    ;;
  *)
    log "k3s state=${st} — start once"
    systemctl start k3s || true
    sleep 20
    ;;
esac

if k3s_api_up; then
  exit 0
fi

# Wait with optional mid-wait vacuum when activating + slow SQL
for i in $(seq 1 "${WAIT_LOOPS}"); do
  if k3s_api_up; then
    log "OK: k3s API ready (attempt ${i}/${WAIT_LOOPS})"
    exit 0
  fi
  elapsed=$(( i * WAIT_SEC ))
  if [[ "$(k3s_unit_state)" == "activating" ]]; then
    maybe_vacuum_if_stuck "${elapsed}" && {
      wait_api "post-vacuum" && exit 0
    }
    log "  [${i}/${WAIT_LOOPS}] activating — waiting (no restart)…"
  else
    log "  [${i}/${WAIT_LOOPS}] state=$(k3s_unit_state) — waiting…"
  fi
  sleep "${WAIT_SEC}"
done

# Last resort: restart only if NOT activating (failed/inactive)
st="$(k3s_unit_state)"
if [[ "${st}" == "activating" ]]; then
  log "ERROR: k3s still activating after long wait — try manual: sudo bash paas/scripts/lab.sh k3s-vacuum"
  exit 1
fi

log "WARN: restarting k3s once (state=${st})"
systemctl restart k3s || true
sleep 30
if wait_api "after restart"; then
  exit 0
fi

log "ERROR: k3s API still down after root ensure"
systemctl status k3s --no-pager 2>&1 | tail -15 || true
journalctl -u k3s -n 25 --no-pager 2>&1 | tail -25 || true
exit 1
