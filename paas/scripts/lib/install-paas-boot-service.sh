#!/usr/bin/env bash
# Install systemd unit so PaaS recovers automatically after VM/k3s boot.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ACTION="${1:-install}"
NODE_IP="${NODE_IP:-192.168.56.129}"
UNIT_PATH="/etc/systemd/system/paas-lab-start.service"
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

do_install() {
  [[ "$(id -u)" -eq 0 ]] || die "run with sudo: sudo bash paas/scripts/lab.sh boot-install"

  [[ -d "${REPO_DIR}" ]] || die "repo not found at ${REPO_DIR}"
  [[ -f "${REPO_DIR}/paas/scripts/lab.sh" ]] || die "lab.sh missing under ${REPO_DIR}"

  chmod +x "${REPO_DIR}/paas/scripts/lab.sh" 2>/dev/null || true
  chmod +x "${REPO_DIR}/paas/scripts/lib/"*.sh 2>/dev/null || true

  if [[ ! -f "${LAB_HOME}/.kube/config" && -f /etc/rancher/k3s/k3s.yaml ]]; then
    install -d -o "${LAB_USER}" -g "${LAB_USER}" -m 700 "${LAB_HOME}/.kube"
    install -o "${LAB_USER}" -g "${LAB_USER}" -m 600 "${LAB_HOME}/.kube/config" /etc/rancher/k3s/k3s.yaml
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
Wants=network-online.target
Requires=k3s.service

[Service]
Type=oneshot
RemainAfterExit=yes
User=${LAB_USER}
WorkingDirectory=${REPO_DIR}
Environment=NODE_IP=${NODE_IP}
Environment=PAAS_FORCE_KYVERNO_UNBLOCK=1
Environment=HOME=${LAB_HOME}
Environment=KUBECONFIG=${KUBECONFIG_PATH}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash ${REPO_DIR}/paas/scripts/lib/paas-boot-start.sh
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${UNIT_PATH}"
  echo "OK: wrote ${UNIT_PATH}"

  if [[ ! -f "${SUDOERS_DROP}" ]]; then
    cat > "${SUDOERS_DROP}" <<EOF
# PaaS lab: k3s image import during frontend-force (no password on boot)
${LAB_USER} ALL=(ALL) NOPASSWD: /usr/local/bin/k3s, /usr/bin/k3s
EOF
    chmod 440 "${SUDOERS_DROP}"
    visudo -cf "${SUDOERS_DROP}" || die "sudoers fragment invalid"
    echo "OK: ${SUDOERS_DROP} (passwordless k3s for ${LAB_USER})"
  else
    echo "OK: ${SUDOERS_DROP} already exists — skipped"
  fi

  systemctl daemon-reload
  systemctl enable paas-lab-start.service
  echo ""
  echo "=============================================="
  echo " Boot service installed"
  echo "  Unit:  ${UNIT_PATH}"
  echo "  Log:   ${LOG_FILE}"
  echo "  User:  ${LAB_USER}"
  echo "  Repo:  ${REPO_DIR}"
  echo ""
  echo " Test now (without reboot):"
  echo "   sudo systemctl start paas-lab-start.service"
  echo "   bash paas/scripts/lab.sh boot-status"
  echo ""
  echo " After reboot (~3–5 min):"
  echo "   http://${NODE_IP}:30100/login"
  echo "=============================================="
}

do_status() {
  systemctl status paas-lab-start.service --no-pager 2>/dev/null || echo "WARN: paas-lab-start.service not installed"
  echo ""
  if [[ -f "${LOG_FILE}" ]]; then
    tail -30 "${LOG_FILE}"
  else
    echo "(no boot log yet — run: sudo systemctl start paas-lab-start.service)"
  fi
}

do_uninstall() {
  [[ "$(id -u)" -eq 0 ]] || die "run with sudo"
  systemctl disable paas-lab-start.service 2>/dev/null || true
  rm -f "${UNIT_PATH}"
  systemctl daemon-reload
  echo "OK: removed paas-lab-start.service"
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
