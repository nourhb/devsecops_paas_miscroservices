#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

NODE="${LAB_MASTER_NODE:-master}"
DISK_OK_PCT="${LAB_MASTER_DISK_OK_PCT:-85}"
API_WAIT_LOOPS="${LAB_MASTER_API_WAIT_LOOPS:-48}"

log() { echo "==> $*"; }

k3s_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif sudo -n true 2>/dev/null; then
    sudo "$@"
  else
    sudo "$@"
  fi
}

node_ready() {
  [[ "$(kubectl get node "${NODE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)" == "True" ]]
}

api_ok() {
  lab_k8s_api_probe "---request-timeout=45s"
}

clear_master_taints() {
  kubectl taint nodes "${NODE}" node.kubernetes.io/unreachable:NoExecute- 2>/dev/null || true
  kubectl taint nodes "${NODE}" node.kubernetes.io/unreachable:NoSchedule- 2>/dev/null || true
  kubectl taint nodes "${NODE}" node.kubernetes.io/disk-pressure:NoSchedule- 2>/dev/null || true
  kubectl taint nodes "${NODE}" node.kubernetes.io/memory-pressure:NoSchedule- 2>/dev/null || true
  kubectl taint nodes "${NODE}" node.kubernetes.io/pid-pressure:NoSchedule- 2>/dev/null || true
}

wait_for_api() {
  local i
  for i in $(seq 1 "${API_WAIT_LOOPS}"); do
    if api_ok && node_ready; then
      log "OK: ${NODE} Ready and API responding (attempt ${i})"
      kubectl get nodes -o wide 2>/dev/null || true
      return 0
    fi
    if api_ok; then
      log "OK: API responding (node Ready pending)"
      return 0
    fi
    echo "  [${i}/${API_WAIT_LOOPS}] waiting for API (no k3s restart)…"
    sleep 5
  done
  return 1
}

log "Master node heal (${NODE})"
kubectl describe node "${NODE}" 2>/dev/null | grep -E '^(Name:|Taints:|Conditions:)' -A10 || true

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo 0)"
log "Disk ${DISK_PCT}% on /"
clear_master_taints

if node_ready && api_ok; then
  log "OK: ${NODE} Ready and API responding"
  exit 0
fi

if node_ready; then
  log "WARN: ${NODE} is Ready but API slow — waiting (LAB_MASTER_K3S_RESTART=1 to force restart)"
  if wait_for_api; then
    exit 0
  fi
  if [[ "${LAB_MASTER_ALLOW_SLOW_API:-1}" == "1" ]]; then
    log "WARN: API still slow — continuing anyway (node Ready)"
    exit 0
  fi
  exit 1
fi

if [[ "${LAB_MASTER_K3S_RESTART:-}" != "1" ]]; then
  log "WARN: ${NODE} not Ready — wait for API/kubelet (set LAB_MASTER_K3S_RESTART=1 to restart k3s)"
  if wait_for_api; then
    exit 0
  fi
  log "ERROR: ${NODE} still not Ready — try: free RAM (free -h), then LAB_MASTER_K3S_RESTART=1 bash $0"
  kubectl describe node "${NODE}" 2>/dev/null | tail -25 || true
  exit 1
fi

log "WARN: restarting k3s once (LAB_MASTER_K3S_RESTART=1)"
k3s_sudo systemctl restart k3s
sleep 90
clear_master_taints

if wait_for_api; then
  exit 0
fi

log "ERROR: ${NODE} still not healthy after k3s restart"
kubectl describe node "${NODE}" 2>/dev/null | tail -25 || true
echo "Try: df -h / && free -h && sudo journalctl -u k3s -n 30 --no-pager" >&2
exit 1
