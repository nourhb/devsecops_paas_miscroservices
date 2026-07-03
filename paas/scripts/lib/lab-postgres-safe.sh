#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
STATE_FILE="${PAAS_POSTGRES_MAINTENANCE_STATE:-/var/tmp/paas-postgres-maintenance-window}"
DEFAULT_REPLICAS="${PAAS_POSTGRES_DEFAULT_REPLICAS:-1}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'

log() { echo "[postgres-safe] $*"; }
warn() { echo "[postgres-safe] WARN: $*" >&2; }

kubectl_try() {
  k3s kubectl "$@" --request-timeout=45s 2>/dev/null \
    || kubectl "$@" --request-timeout=45s 2>/dev/null \
    || return 1
}

postgres_replicas() {
  kubectl_try get deployment postgres -n "${PAAS_NS}" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo ""
}

write_state() {
  local reason="${1:-maintenance}" prior="${2:-1}"
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

postgres_pod_ready() {
  local ready
  ready="$(kubectl_try get deployment postgres -n "${PAAS_NS}" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -ge 1 ]]
}

postgres_ready() {
  if postgres_pod_ready; then
    return 0
  fi
  kubectl_try exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1
}

wait_postgres_ready() {
  local i
  for i in $(seq 1 36); do
    if postgres_ready; then
      log "OK: postgres pg_isready (${i} checks)"
      return 0
    fi
    kubectl_try get pods -n "${PAAS_NS}" -l app=postgres -o wide 2>/dev/null || true
    log "  waiting postgres… (${i}/36)"
    sleep 10
  done
  warn "postgres not ready
  return 1
}

restore_postgres() {
  local target="${1:-}"
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  if [[ -z "${target}" ]] && state_active; then
    source "${STATE_FILE}" 2>/dev/null || true
    target="${prior_replicas:-${DEFAULT_REPLICAS}}"
  fi
  [[ -n "${target}" ]] || target="${DEFAULT_REPLICAS}"
  [[ "${target}" -gt 0 ]] || target="${DEFAULT_REPLICAS}"

  if ! kubectl_try get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
    warn "postgres deployment missing — applying manifest"
    kubectl_try apply -f "${REPO_ROOT}/paas/k8s-manifests/lab/postgres-in-paas.yaml" || true
  fi

  log "restore postgres — replicas=${target}"
  kubectl_try scale deployment/postgres -n "${PAAS_NS}" --replicas="${target}" \
    || warn "scale postgres failed

  wait_postgres_ready || true

  kubectl_try set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" \
    --containers=frontend 2>/dev/null || true
  kubectl_try rollout restart deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true

  clear_state

  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 \
    "http://${NODE_IP}:${PAAS_PORT}/api/health" 2>/dev/null || echo 000)"
  log "UI /api/health HTTP ${code}"
  return 0
}

ensure_postgres_up() {
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  if state_active; then
    log "found active postgres maintenance state — restoring"
    restore_postgres
    return 0
  fi
  local reps
  reps="$(postgres_replicas)"
  if [[ "${reps}" == "0" ]]; then
    warn "postgres replicas=0 — orphaned scale-down; restoring"
    restore_postgres "${DEFAULT_REPLICAS}"
    return 0
  fi
  if [[ "${reps}" == "1" ]] && ! postgres_ready; then
    log "postgres replicas=1 but not ready — waiting once"
    wait_postgres_ready || true
  fi
  return 0
}

run_maintenance() {
  local reason="${1:-postgres-maintenance}"
  shift || true
  [[ "$#" -gt 0 ]] || {
    echo "usage: lab-postgres-safe.sh run <reason> <command...>" >&2
    exit 1
  }

  trap 'restore_postgres' EXIT INT TERM
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  local prior
  prior="$(postgres_replicas)"
  [[ -n "${prior}" ]] || prior="${DEFAULT_REPLICAS}"
  write_state "${reason}" "${prior}"

  echo ""
  echo "=============================================="
  echo " Postgres maintenance window"
  echo "=============================================="
  echo "  Command: $*"
  echo "  Postgres restores automatically on exit/error."
  echo "  If SSH drops: bash paas/scripts/lab.sh postgres-up"
  echo "=============================================="
  echo ""

  "$@"
  log "maintenance command finished — restoring postgres"
}

begin_maintenance() {
  local reason="${1:-postgres-maintenance}"
  trap 'restore_postgres' EXIT INT TERM
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  local prior
  prior="$(postgres_replicas)"
  [[ -n "${prior}" ]] || prior="${DEFAULT_REPLICAS}"
  write_state "${reason}" "${prior}"
  log "maintenance started (${reason}) — postgres restores on exit"
}

cmd="${1:-ensure}"
shift || true
case "${cmd}" in
  ensure) ensure_postgres_up ;;
  restore|up) restore_postgres "${1:-}" ;;
  begin) begin_maintenance "${1:-postgres-maintenance}" ;;
  run) run_maintenance "$@" ;;
  *)
    echo "usage: lab-postgres-safe.sh {ensure|restore|begin|run <reason> <cmd...>}" >&2
    exit 1
    ;;
esac
