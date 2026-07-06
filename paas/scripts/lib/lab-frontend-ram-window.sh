#!/usr/bin/env bash
# Lab script to frontend ram window on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
STATE_FILE="${PAAS_FRONTEND_RAM_WINDOW_STATE:-/var/tmp/paas-frontend-ram-window}"
DEFAULT_REPLICAS="${PAAS_FRONTEND_DEFAULT_REPLICAS:-1}"
WINDOW_MAX_MIN="${PAAS_RAM_WINDOW_MAX_MIN:-45}"

log() { echo "[frontend-ram-window] $*"; }
warn() { echo "[frontend-ram-window] WARN: $*" >&2; }

kubectl_try() {
  k3s kubectl "$@" --request-timeout=30s 2>/dev/null \
    || kubectl "$@" --request-timeout=30s 2>/dev/null \
    || return 1
}

frontend_replicas() {
  kubectl_try get deployment frontend -n "${PAAS_NS}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo ""
}

frontend_paused() {
  kubectl_try get deployment frontend -n "${PAAS_NS}" \
    -o jsonpath='{.spec.paused}' 2>/dev/null || echo false
}

write_state() {
  local reason="${1:-ram-window}" prior="${2:-1}"
  mkdir -p "$(dirname "${STATE_FILE}")"
  cat >"${STATE_FILE}" <<EOF
reason=${reason}
prior_replicas=${prior}
started_at=$(date -Is 2>/dev/null || date)
pid=$$
EOF
}

clear_state() {
  rm -f "${STATE_FILE}" 2>/dev/null || true
}

state_active() {
  [[ -f "${STATE_FILE}" ]]
}

pause_frontend() {
  local reason="${1:-sonar-scan-window}"
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  local prior
  prior="$(frontend_replicas)"
  [[ -n "${prior}" ]] || prior="${DEFAULT_REPLICAS}"
  [[ "${prior}" -gt 0 ]] || prior="${DEFAULT_REPLICAS}"
  write_state "${reason}" "${prior}"
  log "pause UI (${reason}) — saving prior replicas=${prior}"
  kubectl_try scale deployment/frontend -n "${PAAS_NS}" --replicas=0 \
    || warn "scale to 0 failed — API may be slow"
  free -h 2>/dev/null | awk '/Mem:/ {print "  mem available: "$7" "$8}' || true
}

restore_frontend() {
  local target="${1:-}"
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  if [[ -z "${target}" ]] && state_active; then
    source "${STATE_FILE}" 2>/dev/null || true
    target="${prior_replicas:-${DEFAULT_REPLICAS}}"
  fi
  [[ -n "${target}" ]] || target="${DEFAULT_REPLICAS}"
  [[ "${target}" -gt 0 ]] || target="${DEFAULT_REPLICAS}"

  log "restore UI — replicas=${target}"
  kubectl_try rollout resume deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
  kubectl_try scale deployment/frontend -n "${PAAS_NS}" --replicas="${target}" \
    || warn "scale to ${target} failed"

  clear_state

  for i in $(seq 1 12); do
    local code ready
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 \
      "http://${NODE_IP}:${PAAS_PORT}/login" 2>/dev/null || echo 000)"
    ready="$(kubectl_try get pods -n "${PAAS_NS}" -l app=frontend \
      -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
    log "  check ${i}/12 pod_ready=${ready} ui_http=${code}"
    if [[ "${ready}" == "true" ]] && [[ "${code}" == "200" || "${code}" == "307" || "${code}" == "308" ]]; then
      log "OK: PaaS UI http://${NODE_IP}:${PAAS_PORT}"
      return 0
    fi
    sleep 10
  done
  warn "UI not HTTP 200 yet"
  return 0
}

ensure_frontend_up() {
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  if state_active; then
    log "found active RAM window state — restoring UI"
    restore_frontend
    return 0
  fi
  local reps paused
  reps="$(frontend_replicas)"
  paused="$(frontend_paused)"
  if [[ "${reps}" == "0" ]] && [[ "${paused}" != "true" ]]; then
    warn "frontend replicas=0 without rollout pause — orphaned scale-down; restoring"
    restore_frontend "${DEFAULT_REPLICAS}"
    return 0
  fi
  if [[ "${reps}" == "0" ]] && [[ "${paused}" == "true" ]]; then
    log "frontend paused at 0 (storm stop) — skip auto restore"
    return 0
  fi
  return 0
}

run_window() {
  local reason="${1:-sonar-scan-window}"
  trap 'restore_frontend' EXIT INT TERM
  pause_frontend "${reason}"
  echo ""
  echo "=============================================="
  echo " RAM window active — PaaS UI paused on purpose"
  echo "=============================================="
  echo "  Trigger Jenkins paas-deploy now (Step 5 needs RAM)."
  echo "  When the build finishes (or you Ctrl+C here), UI restores automatically."
  echo "  If SSH drops: bash paas/scripts/lab.sh frontend-up"
  echo "  Max wait: ${WINDOW_MAX_MIN} min"
  echo "=============================================="
  echo ""
  local deadline=$(( $(date +%s) + WINDOW_MAX_MIN * 60 ))
  while [[ $(date +%s) -lt "${deadline}" ]]; do
    sleep 30
  done
  log "max wait ${WINDOW_MAX_MIN}m — restoring UI"
}

cmd="${1:-ensure}"
case "${cmd}" in
  pause) pause_frontend "${2:-sonar-scan-window}" ;;
  restore|up) restore_frontend "${2:-}" ;;
  ensure) ensure_frontend_up ;;
  run|window|sonar) run_window "${2:-sonar-scan-window}" ;;
  *)
    echo "usage: lab-frontend-ram-window.sh {pause|restore|ensure|run}" >&2
    exit 1
    ;;
esac
