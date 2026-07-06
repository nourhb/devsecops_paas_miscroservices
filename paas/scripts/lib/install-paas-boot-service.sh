#!/usr/bin/env bash
# Lab helper script for install paas boot service
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ACTION="${1:-install}"
NODE_IP="${NODE_IP:-192.168.56.129}"
UNIT_PATH="/etc/systemd/system/paas-lab-start.service"
TIMER_PATHS=(
  "/etc/systemd/system/paas-lab-start-retry.timer"
  "/etc/systemd/system/paas-lab-start-retry2.timer"
  "/etc/systemd/system/paas-lab-start-retry3.timer"
)
LOG_FILE="/var/log/paas-lab-start.log"
SUDOERS_DROP="/etc/sudoers.d/paas-lab-k3s"

die() { echo "ERROR: $*" >&2; exit 1; }

resolve_lab_user() {
  if [[ -n "${PAAS_LAB_USER:-}" ]]; then
    echo "${PAAS_LAB_USER}"
    return
  fi
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    echo "${SUDO_USER}"
    return
  fi
  local owner
  owner="$(stat -c '%U' "${REPO_DIR}" 2>/dev/null || true)"
  if [[ -n "${owner}" && "${owner}" != "root" ]]; then
    echo "${owner}"
    return
  fi
  echo "master"
}

REPO_DIR="${PAAS_REPO_DIR:-${REPO_ROOT}}"
LAB_USER="$(resolve_lab_user)"
LAB_HOME="$(getent passwd "${LAB_USER}" | cut -d: -f6)"
[[ -n "${LAB_HOME}" ]] || die "no passwd entry for user ${LAB_USER}"

write_retry_timer() {
  local path="$1"
  local boot_sec="$2"
  cat > "${path}" <<EOF
[Unit]
Description=Retry PaaS lab recover (${boot_sec} after boot)
After=k3s.service network-online.target

[Timer]
OnBootSec=${boot_sec}
Unit=paas-lab-start.service
Persistent=true

[Install]
WantedBy=timers.target
EOF
  chmod 644 "${path}"
}

do_install() {
  [[ "$(id -u)" -eq 0 ]] || die "run with sudo: sudo bash paas/scripts/lab.sh boot-install"

  [[ -d "${REPO_DIR}" ]] || die "repo not found at ${REPO_DIR}"
  [[ -f "${REPO_DIR}/paas/scripts/lab.sh" ]] || die "lab.sh missing under ${REPO_DIR}"

  chmod +x "${REPO_DIR}/paas/scripts/lab.sh" 2>/dev/null || true
  chmod +x "${REPO_DIR}/paas/scripts/lib/"*.sh 2>/dev/null || true
  chmod +x "${REPO_DIR}/paas/scripts/lib/paas-boot-start.sh" 2>/dev/null || true
  chmod +x "${REPO_DIR}/paas/scripts/lib/paas-boot-k3s-root.sh" 2>/dev/null || true

  K3S_ROOT_HELPER="/usr/local/sbin/paas-boot-k3s-root.sh"
  install -m 755 "${REPO_DIR}/paas/scripts/lib/paas-boot-k3s-root.sh" "${K3S_ROOT_HELPER}"
  echo "OK: installed ${K3S_ROOT_HELPER} (runs as root on boot)"

  install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 700 "${LAB_HOME}/.kube"
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    install -o "${LAB_USER}" -g "${LAB_USER}" -m 600 /etc/rancher/k3s/k3s.yaml "${LAB_HOME}/.kube/config"
    echo "OK: kubeconfig for ${LAB_USER} at ${LAB_HOME}/.kube/config"
  fi

  KUBECONFIG_PATH="${LAB_HOME}/.kube/config"
  if [[ ! -f "${KUBECONFIG_PATH}" && -r /etc/rancher/k3s/k3s.yaml ]]; then
    KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"
  fi

  touch "${LOG_FILE}"
  chown "${LAB_USER}:${LAB_USER}" "${LOG_FILE}" 2>/dev/null || true

  if systemctl list-unit-files k3s.service >/dev/null 2>&1; then
    systemctl enable k3s.service 2>/dev/null || true
    echo "OK: k3s.service enabled on boot"
  else
    echo "WARN: k3s.service not found — install k3s first"
  fi

  cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=PaaS lab auto-recover after k3s boot
After=k3s.service network-online.target
Wants=network-online.target k3s.service
StartLimitIntervalSec=0

[Service]
Type=oneshot
RemainAfterExit=yes
User=${LAB_USER}
WorkingDirectory=${REPO_DIR}
Environment=NODE_IP=${NODE_IP}
Environment=PAAS_FORCE_KYVERNO_UNBLOCK=1
Environment=PAAS_BOOT_RECOVER=1
Environment=PAAS_BOOT_K3S_ROOT_DONE=1
Environment=PAAS_SKIP_KYVERNO_RESTART=1
Environment=HOME=${LAB_HOME}
Environment=KUBECONFIG=${KUBECONFIG_PATH}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStartPre=+/bin/bash ${K3S_ROOT_HELPER}
ExecStart=/bin/bash ${REPO_DIR}/paas/scripts/lib/paas-boot-start.sh
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
TimeoutStartSec=1200

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${UNIT_PATH}"
  echo "OK: wrote ${UNIT_PATH}"

  write_retry_timer "${TIMER_PATHS[0]}" "5min"
  write_retry_timer "${TIMER_PATHS[1]}" "10min"
  write_retry_timer "${TIMER_PATHS[2]}" "18min"
  echo "OK: retry timers at 5 / 10 / 18 min after boot"

  cat > "${SUDOERS_DROP}" <<EOF
${LAB_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/k3s, /usr/bin/k3s
${LAB_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart k3s, /usr/bin/systemctl start k3s, /usr/bin/systemctl is-active k3s
${LAB_USER} ALL=(ALL) NOPASSWD: /bin/systemctl restart k3s, /bin/systemctl start k3s, /bin/systemctl is-active k3s
EOF
  chmod 440 "${SUDOERS_DROP}"
  visudo -cf "${SUDOERS_DROP}" || die "sudoers fragment invalid"
  echo "OK: ${SUDOERS_DROP} (passwordless k3s + systemctl for ${LAB_USER})"

  systemctl daemon-reload
  systemctl enable paas-lab-start.service
  systemctl enable paas-lab-start-retry.timer
  systemctl enable paas-lab-start-retry2.timer
  systemctl enable paas-lab-start-retry3.timer
  systemctl start paas-lab-start-retry.timer 2>/dev/null || true
  systemctl start paas-lab-start-retry2.timer 2>/dev/null || true
  systemctl start paas-lab-start-retry3.timer 2>/dev/null || true
  echo ""
  echo "=============================================="
  echo " Boot auto-start INSTALLED"
  echo "  On VM power-on: wait 5–15 min, then open:"
  echo "  http://${NODE_IP}:30100/login"
  echo ""
  echo "  Log:   ${LOG_FILE}"
  echo "  User:  ${LAB_USER}"
  echo "  Repo:  ${REPO_DIR}"
  echo ""
  echo " Test without reboot:"
  echo "   sudo systemctl start paas-lab-start.service"
  echo "   bash paas/scripts/lab.sh boot-status"
  echo "=============================================="
}

do_status() {
  systemctl status paas-lab-start.service --no-pager 2>/dev/null || echo "WARN: paas-lab-start.service not installed"
  echo ""
  systemctl list-timers --all 2>/dev/null | grep -E 'paas-lab-start|NEXT' || true
  echo ""
  if [[ -f /var/tmp/paas-lab-boot-ok ]]; then
    echo "OK: last boot marked healthy at $(cat /var/tmp/paas-lab-boot-ok)"
  fi
  echo ""
  if [[ -f "${LOG_FILE}" ]]; then
    tail -40 "${LOG_FILE}"
  else
    echo "(no boot log yet — run: sudo systemctl start paas-lab-start.service)"
  fi
}

do_uninstall() {
  [[ "$(id -u)" -eq 0 ]] || die "run with sudo"
  systemctl disable paas-lab-start.service 2>/dev/null || true
  systemctl disable paas-lab-start-retry.timer 2>/dev/null || true
  systemctl disable paas-lab-start-retry2.timer 2>/dev/null || true
  systemctl disable paas-lab-start-retry3.timer 2>/dev/null || true
  rm -f "${UNIT_PATH}" "${TIMER_PATHS[@]}"
  systemctl daemon-reload
  echo "OK: removed paas-lab-start boot units"
}

case "${ACTION}" in
  install) do_install ;;
  start)
    [[ "$(id -u)" -eq 0 ]] || die "run: sudo systemctl start paas-lab-start.service"
    systemctl start paas-lab-start.service
    ;;
  status) do_status ;;
  uninstall) do_uninstall ;;
  *)
    echo "usage: install-paas-boot-service.sh [install|start|status|uninstall]" >&2
    exit 1
    ;;
esac
