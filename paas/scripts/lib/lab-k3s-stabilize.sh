#!/usr/bin/env bash
# Lab script to k3s stabilize on VM cluster
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

NODE="${LAB_MASTER_NODE:-master}"

log() { echo "==> $*"; }

k3s_sudo() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

k3s_service_state() {
  systemctl is-active k3s 2>/dev/null || echo inactive
}

ensure_k3s_service() {
  local st
  st="$(k3s_service_state)"
  case "${st}" in
    active)
      log "k3s service active — will NOT systemctl start/restart"
      return 0
      ;;
    activating)
      log "k3s service activating — waiting (will NOT systemctl start)"
      sleep 30
      return 0
      ;;
    failed)
      log "k3s service failed — reset-failed + start once"
      k3s_sudo systemctl reset-failed k3s 2>/dev/null || true
      k3s_sudo systemctl start k3s || {
        log "ERROR: systemctl start k3s failed — sudo journalctl -u k3s -n 50 --no-pager"
        return 1
      }
      sleep 30
      ;;
    inactive|dead)
      log "k3s service inactive — start once (not restart)"
      k3s_sudo systemctl start k3s || {
        log "ERROR: systemctl start k3s failed — sudo journalctl -u k3s -n 50 --no-pager"
        return 1
      }
      sleep 30
      ;;
    *)
      log "k3s service state=${st} — waiting only (no systemctl start)"
      ;;
  esac
  return 0
}

ensure_k3s_service || exit 1

log "Wait for k8s API (no k3s restart unless LAB_MASTER_K3S_RESTART=1)"
if ! lab_k8s_api_wait; then
  if [[ "${LAB_MASTER_K3S_RESTART:-}" == "1" ]]; then
    log "LAB_MASTER_K3S_RESTART=1 — restarting k3s once"
    k3s_sudo systemctl restart k3s
    sleep 90
    lab_k8s_api_wait || exit 1
  else
    log "ERROR: API still down after wait"
    log "  sudo systemctl status k3s --no-pager | head -20"
    log "  sudo journalctl -u k3s -n 50 --no-pager"
    log "  free -h"
    log "  If OOM: free RAM, then LAB_MASTER_K3S_RESTART=1 bash $0"
    exit 1
  fi
fi

log "Clear stale taints on ${NODE}"
kubectl taint nodes "${NODE}" node.kubernetes.io/unreachable:NoExecute- 2>/dev/null || true
kubectl taint nodes "${NODE}" node.kubernetes.io/unreachable:NoSchedule- 2>/dev/null || true
kubectl taint nodes "${NODE}" node.kubernetes.io/disk-pressure:NoSchedule- 2>/dev/null || true
kubectl taint nodes "${NODE}" node.kubernetes.io/memory-pressure:NoSchedule- 2>/dev/null || true

kubectl get nodes -o wide 2>/dev/null || true
log "OK: k3s API up, ${NODE} taints cleared"
