#!/usr/bin/env bash
# Sync Argo CD Applications without relying on an expired `argocd` CLI session.
# Source from lab scripts: source "$(dirname "$0")/lib/argo-sync-lab.sh"

argo_load_lab_env() {
  local root="${1:-}"
  [[ -n "${root}" ]] || return 0
  local env_file="${ENV_FILE:-${root}/frontend/docker-compose.env}"
  [[ -f "${env_file}" ]] || return 0
  set +u
  # shellcheck disable=SC1090
  source "${env_file}" 2>/dev/null || true
  set -u
}

# Trigger sync via Application CR (works with kubectl admin — no argocd login required).
argo_sync_app_kubectl() {
  local app="$1"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  [[ -n "${app}" ]] || return 1
  if ! kubectl get application "${app}" -n "${ns}" >/dev/null 2>&1; then
    echo "WARN: Application ${app} not found in ${ns}" >&2
    return 1
  fi
  kubectl annotate application "${app}" -n "${ns}" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  if kubectl patch application "${app}" -n "${ns}" --type merge -p '{
    "operation": {
      "initiatedBy": {"username": "lab-fix"},
      "sync": {
        "revision": "HEAD",
        "prune": false,
        "syncStrategy": {"apply": {"force": true}}
      }
    }
  }' >/dev/null 2>&1; then
    echo "OK: kubectl sync triggered for ${app}"
    return 0
  fi
  echo "WARN: kubectl patch sync failed for ${app}" >&2
  return 1
}

# Optional: fresh argocd CLI login when ARGOCD_PASSWORD is set in docker-compose.env.
argo_sync_app_cli() {
  local app="$1"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  command -v argocd >/dev/null 2>&1 || return 1
  local base="${ARGOCD_BASE_URL:-}"
  local user="${ARGOCD_USERNAME:-admin}"
  local pass="${ARGOCD_PASSWORD:-}"
  [[ -n "${base}" && -n "${pass}" ]] || return 1
  local host port scheme
  if [[ "${base}" =~ ^https?://([^:/]+):?([0-9]*) ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    scheme="http"
    [[ "${base}" == https* ]] && scheme="https"
  else
    return 1
  fi
  local login_args=(--username "${user}" --password "${pass}" --insecure --grpc-web)
  [[ -n "${port}" ]] && login_args+=(--port "${port}") || true
  argocd login "${host}" "${login_args[@]}" >/dev/null 2>&1 || return 1
  argocd app sync "${app}" --force >/dev/null 2>&1 && {
    echo "OK: argocd CLI sync for ${app}"
    return 0
  }
  return 1
}

argo_sync_app_lab() {
  local app="$1"
  argo_sync_app_kubectl "${app}" && return 0
  argo_sync_app_cli "${app}" && return 0
  return 1
}

argo_wait_app_lab() {
  local app="$1"
  local timeout="${2:-300}"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local health sync op
    health="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
    sync="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")"
    op="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.operationState.phase}' 2>/dev/null || echo "")"
    if [[ "${health}" == "Healthy" && "${sync}" == "Synced" ]]; then
      echo "OK: ${app} Healthy+Synced"
      return 0
    fi
    if [[ "${sync}" == "Unknown" && -n "${op}" && "${op}" != "Succeeded" && "${op}" != "Failed" ]]; then
      echo "  … sync=${sync} health=${health} operation=${op}"
    fi
    sleep 5
  done
  local health sync op
  health="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "?")"
  sync="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "?")"
  op="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.operationState.phase}{" "}{.status.operationState.message}' 2>/dev/null || echo "")"
  echo "WARN: ${app} not Healthy+Synced within ${timeout}s (health=${health} sync=${sync} op=${op})"
  return 1
}
