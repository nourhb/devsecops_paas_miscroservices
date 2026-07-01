#!/usr/bin/env bash
# Wait for / start k3s — restart only if API still dead after a short wait.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

if [[ "${PAAS_BOOT_K3S_ROOT_DONE:-0}" == "1" ]] || [[ "${PAAS_BOOT_RECOVER:-0}" == "1" ]]; then
  LAB_K3S_WAIT_LOOPS="${LAB_K3S_WAIT_LOOPS:-72}"
  LAB_K3S_WAIT_SEC="${LAB_K3S_WAIT_SEC:-10}"
else
  LAB_K3S_WAIT_LOOPS="${LAB_K3S_WAIT_LOOPS:-12}"
  LAB_K3S_WAIT_SEC="${LAB_K3S_WAIT_SEC:-5}"
fi

lab_sudo_systemctl() {
  local action="$1"
  if sudo -n "/usr/bin/systemctl" "${action}" k3s 2>/dev/null; then
    return 0
  fi
  if sudo -n "/bin/systemctl" "${action}" k3s 2>/dev/null; then
    return 0
  fi
  if [[ "$(id -u)" -eq 0 ]]; then
    systemctl "${action}" k3s
    return $?
  fi
  echo "WARN: cannot ${action} k3s without password — run: sudo bash paas/scripts/lab.sh boot-install" >&2
  return 1
}

lab_k3s_wait_api() {
  local i
  for i in $(seq 1 "${LAB_K3S_WAIT_LOOPS}"); do
    if lab_k8s_api_ready; then
      echo "OK: k3s API ready (attempt ${i}/${LAB_K3S_WAIT_LOOPS})"
      return 0
    fi
    echo "  [${i}/${LAB_K3S_WAIT_LOOPS}] k3s API not ready yet…"
    sleep "${LAB_K3S_WAIT_SEC}"
  done
  return 1
}

lab_k3s_service_active() {
  timeout 20 systemctl is-active k3s >/dev/null 2>&1
}

if [[ "${LAB_K3S_FORCE_RESTART:-}" == "1" ]]; then
  echo "WARN: LAB_K3S_FORCE_RESTART=1 — restarting k3s"
  lab_sudo_systemctl restart || true
  sleep 20
  lab_k3s_wait_api && exit 0
fi

if lab_k8s_api_ready; then
  echo "OK: k3s API already up"
  exit 0
fi

# Boot service runs paas-boot-k3s-root.sh as root in ExecStartPre — never restart k3s here.
if [[ "${PAAS_BOOT_K3S_ROOT_DONE:-0}" == "1" ]] || [[ "${PAAS_BOOT_RECOVER:-0}" == "1" ]]; then
  if lab_k8s_api_ready || lab_k3s_wait_api; then
    exit 0
  fi
  echo "ERROR: k3s API still down after root boot pre-step" >&2
  echo "  sudo journalctl -u k3s -n 40 --no-pager" >&2
  echo "  sudo bash paas/scripts/lab.sh k3s-vacuum" >&2
  exit 1
fi

echo "WARN: k3s API not reachable"
if systemctl is-active k3s >/dev/null 2>&1 || systemctl show -p ActiveState k3s 2>/dev/null | grep -q activating; then
  echo "==> k3s.service is active/activating — wait up to $(( LAB_K3S_WAIT_LOOPS * LAB_K3S_WAIT_SEC ))s (no restart)"
  if lab_k3s_wait_api; then
    exit 0
  fi
  echo "ERROR: k3s active/activating but API still down — run: sudo bash paas/scripts/lab.sh k3s-vacuum" >&2
  exit 1
fi

echo "WARN: k3s.service not active — starting once"
lab_sudo_systemctl start || true
sleep 15
if lab_k3s_wait_api; then
  exit 0
fi

echo "ERROR: k3s API still down after start" >&2
echo "  k3s kubectl get nodes" >&2
echo "  sudo systemctl status k3s --no-pager" >&2
echo "  sudo journalctl -u k3s -n 40 --no-pager" >&2
echo "  sudo bash paas/scripts/lab.sh k3s-vacuum" >&2
exit 1
