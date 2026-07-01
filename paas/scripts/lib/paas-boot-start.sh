#!/usr/bin/env bash
# systemd ExecStart — PaaS recover after VM/k3s boot (no manual SSH required).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

BOOT_OK_MARKER="/var/tmp/paas-lab-boot-ok"
BOOT_PROGRESS="/var/tmp/paas-lab-boot-in-progress"
LOG_TAG="paas-boot"

log() {
  echo "[$(date -Is 2>/dev/null || date)] ${LOG_TAG}: $*"
}

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export PAAS_FORCE_KYVERNO_UNBLOCK="${PAAS_FORCE_KYVERNO_UNBLOCK:-1}"
export PAAS_BOOT_RECOVER="${PAAS_BOOT_RECOVER:-1}"
export PAAS_BOOT_K3S_ROOT_DONE="${PAAS_BOOT_K3S_ROOT_DONE:-1}"
export PAAS_SKIP_KYVERNO_RESTART="${PAAS_SKIP_KYVERNO_RESTART:-1}"
export NODE_IP="${NODE_IP:-192.168.56.129}"
export PAAS_NS="${PAAS_NS:-paas}"

chmod +x "${REPO_ROOT}/paas/scripts/lab.sh" 2>/dev/null || true
chmod +x "${REPO_ROOT}/paas/scripts/lib/"*.sh 2>/dev/null || true
lab_sync_kubeconfig || lab_ensure_kubeconfig || true

date -Is > "${BOOT_PROGRESS}" 2>/dev/null || true
trap 'rm -f "${BOOT_PROGRESS}" 2>/dev/null || true' EXIT

if bash "${SCRIPT_DIR}/check-paas-lab-health.sh" 2>/dev/null; then
  log "already healthy — skip recover"
  date -Is > "${BOOT_OK_MARKER}" 2>/dev/null || true
  bash "${SCRIPT_DIR}/lab-guard-cron.sh" install 2>/dev/null || true
  exit 0
fi

rm -f "${BOOT_OK_MARKER}" 2>/dev/null || true

log "start (repo=${REPO_ROOT})"
log "KUBECONFIG=${KUBECONFIG:-unset}"

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo 0)"
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 85 ]]; then
  log "WARN: disk at ${DISK_PCT}% — free space before recover"
  if [[ -f "${SCRIPT_DIR}/lab-disk-emergency-free.sh" ]]; then
    bash "${SCRIPT_DIR}/lab-disk-emergency-free.sh" 2>&1 || true
  fi
fi

if [[ -f "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" ]]; then
  bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true
fi

log "ensure k3s API (root pre-step should have completed)"
if ! bash "${SCRIPT_DIR}/lab-k3s-ensure.sh"; then
  log "ERROR: k3s not ready — retry timer will run again"
  exit 1
fi

kubectl taint nodes master node.kubernetes.io/unreachable:NoExecute- 2>/dev/null || true
kubectl taint nodes master node.kubernetes.io/unreachable:NoSchedule- 2>/dev/null || true

log "quick health probe"
if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
  log "already healthy — boot success"
  date -Is > "${BOOT_OK_MARKER}" 2>/dev/null || true
  bash "${SCRIPT_DIR}/lab-guard-cron.sh" install 2>/dev/null || true
  exit 0
fi

log "lightweight recover via quick-up (no k3s restart, no scale-to-0 storm)"
if bash "${SCRIPT_DIR}/lab-quick-up.sh"; then
  log "quick-up OK"
elif [[ -f "${SCRIPT_DIR}/lab-paas-db-repair.sh" ]]; then
  log "quick-up failed — one db-repair then retry quick-up"
  PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" 2>/dev/null || true
  bash "${SCRIPT_DIR}/lab-quick-up.sh" 2>/dev/null || true
fi

log "waiting for health (up to ~8 min)"
for i in $(seq 1 32); do
  if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
    log "health OK on attempt ${i}"
    date -Is > "${BOOT_OK_MARKER}" 2>/dev/null || true
    bash "${SCRIPT_DIR}/lab-guard-cron.sh" install 2>/dev/null || true
    log "boot success — http://${NODE_IP}:30100/login"
    exit 0
  fi
  log "health not ready (${i}/32) — retry in 15s"
  sleep 15
done

log "WARN: boot incomplete — retry timers at 5 / 10 / 18 min"
exit 1
