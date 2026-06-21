#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
LOG_TAG="lab-watchdog"
HEALED=0

log() { echo "${LOG_TAG}: $*"; }
healed() { HEALED=1; log "healed — $*"; }

disk_pct() {
  df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}'
}

master_disk_pressure() {
  kubectl describe node master 2>/dev/null | grep -q 'DiskPressure.*True'
}

frontend_pod_count() {
  kubectl get pods -n "${PAAS_NS}" -l app=frontend --no-headers 2>/dev/null | wc -l | tr -d ' '
}

frontend_failed_count() {
  kubectl get pods -n "${PAAS_NS}" -l app=frontend --field-selector=status.phase=Failed --no-headers 2>/dev/null | wc -l | tr -d ' '
}

postgres_ready() {
  [[ "$(kubectl get pods -n "${PAAS_NS}" -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)" == "True" ]]
}

frontend_tcp_postgres() {
  kubectl exec -n "${PAAS_NS}" deploy/frontend -- node -e "
const n=require('net');const s=n.connect(5432,'postgres');
s.on('connect',()=>process.exit(0));s.on('error',()=>process.exit(1));
setTimeout(()=>process.exit(1),5000);
" >/dev/null 2>&1
}

ensure_frontend_lab_safety() {
  if [[ -f "${SCRIPT_DIR}/lab-frontend-lab-safety.sh" ]]; then
    source "${SCRIPT_DIR}/lab-frontend-lab-safety.sh"
    if frontend_storm_active 3; then
      stop_frontend_storm_if_needed 3
      healed "stopped frontend pod storm (>3 pods)"
    fi
    if ! ensure_lab_frontend_safety 2>/dev/null; then
      log "frontend safety patch skipped or failed"
    fi
  fi
}

auto_heal_blocked() {
  [[ -f /var/tmp/paas-lab-no-auto-heal ]]
}

cooldown_ok() {
  local state="$1" sec="${2:-900}"
  [[ -f "${state}" ]] || return 0
  local last now
  last="$(cat "${state}" 2>/dev/null || echo 0)"
  now="$(date +%s)"
  (( now - last >= sec ))
}

mark_action() {
  date +%s > "$1" 2>/dev/null || sudo sh -c "date +%s > $1" 2>/dev/null || true
}

log "tick — $(date -Is 2>/dev/null || date)"

if auto_heal_blocked; then
  log "auto-heal paused (/var/tmp/paas-lab-no-auto-heal) — skip"
  exit 0
fi

if ! timeout 15 kubectl get --raw=/healthz >/dev/null 2>&1; then
  log "k8s API not ready — skip"
  exit 0
fi

bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard && true

DISK="$(disk_pct)"
log "disk ${DISK:-?}%"

FC="$(frontend_pod_count)"
if [[ "${FC}" -gt 3 ]]; then
  bash "${SCRIPT_DIR}/lab-frontend-stop-storm.sh" || true
  bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh" || true
  healed "frontend pod storm (${FC} pods) — stop + force recover"
fi

ensure_frontend_lab_safety

if master_disk_pressure || { [[ -n "${DISK}" && "${DISK}" -ge 90 ]]; }; then
  FC="$(frontend_pod_count)"
  FR="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  if [[ "${FC}" -gt 2 || "${FR}" -gt 1 ]]; then
    bash "${SCRIPT_DIR}/lab-frontend-stop-storm.sh" || true
    healed "stopped frontend pod storm (disk pressure or >=90%)"
  elif [[ "${FR}" == "1" && "${DISK}" -ge 92 ]]; then
    kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
    kubectl rollout pause deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
    healed "scaled frontend to 0 (disk >=92%)"
  fi
  bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true
  kubectl taint nodes master node.kubernetes.io/disk-pressure:NoSchedule- 2>/dev/null || true
fi

if [[ -n "${DISK}" && "${DISK}" -ge 85 ]]; then
  bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true
  bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" prune || true
fi

FF="$(frontend_failed_count)"
if [[ "${FF}" -gt 5 ]]; then
  bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true
  healed "bulk-deleted ${FF} failed frontend pods"
fi

if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  if ! postgres_ready; then
    if cooldown_ok /var/tmp/paas-lab-postgres-restart.ts 1800; then
      log "postgres not ready — restart (max once per 30m)"
      kubectl rollout restart deployment/postgres -n "${PAAS_NS}" 2>/dev/null || true
      mark_action /var/tmp/paas-lab-postgres-restart.ts
      healed "postgres restarted"
    else
      log "postgres not ready — cooldown active, skip restart"
    fi
  fi
fi

if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  REPLICAS="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  PAUSED="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.paused}' 2>/dev/null || echo false)"
  WAIT_REASON="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"

  if [[ "${WAIT_REASON}" == ImagePullBackOff || "${WAIT_REASON}" == ErrImageNeverPull ]]; then
    if [[ -n "${DISK}" && "${DISK}" -lt 88 ]]; then
      bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh" || log "frontend-force failed"
      healed "frontend image pull (${WAIT_REASON}) — force recover on master"
    fi
  fi

  if [[ "${REPLICAS}" == "0" && "${PAUSED}" != "true" ]] && postgres_ready \
      && [[ -n "${DISK}" && "${DISK}" -lt 85 ]]; then
    kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1 2>/dev/null || true
    healed "scaled frontend to 1 (postgres up, disk ok)"
  fi

  if [[ "${REPLICAS}" -ge 1 ]] && postgres_ready; then
    if ! frontend_tcp_postgres 2>/dev/null; then
      if cooldown_ok /var/tmp/paas-lab-db-repair.ts 900; then
        log "frontend cannot reach postgres — db-repair (max once per 15m)"
        bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || log "db-repair failed"
        mark_action /var/tmp/paas-lab-db-repair.ts
        healed "ran db-repair"
      else
        log "postgres TCP fail — db-repair cooldown, skip"
      fi
    fi
  fi
fi

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:${PAAS_PORT}/api/health" 2>/dev/null || echo 000)"
if [[ "${HTTP}" == "500" ]] && postgres_ready && [[ -n "${DISK}" && "${DISK}" -lt 85 ]]; then
  if ! frontend_tcp_postgres 2>/dev/null && cooldown_ok /var/tmp/paas-lab-db-repair.ts 900; then
    bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
    mark_action /var/tmp/paas-lab-db-repair.ts
    healed "api/health 500 — db-repair"
  fi
fi

if [[ "${HEALED}" -eq 0 ]]; then
  log "no action needed"
else
  log "done — one or more auto-heals applied"
fi
