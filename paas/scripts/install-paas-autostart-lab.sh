#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO="${PAAS_REPO:-$DEFAULT_REPO}"
UNIT_PATH="/etc/systemd/system/paas-lab-recover.service"
RECOVER="${REPO}/paas/scripts/recover-paas-after-k3s-restart.sh"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo from the repo (do not rely on root's \$HOME):" >&2
  echo "  cd ~/devsecops_paas_miscroservices && sudo bash paas/scripts/install-paas-autostart-lab.sh" >&2
  exit 1
fi

if [[ ! -f "${RECOVER}" ]]; then
  echo "ERROR: recover script not found: ${RECOVER}" >&2
  echo "Set PAAS_REPO to your clone, e.g. PAAS_REPO=/home/master/devsecops_paas_miscroservices" >&2
  exit 1
fi

REPO_OWNER="$(stat -c '%U' "${REPO}" 2>/dev/null || echo master)"
REPO_OWNER_HOME="$(getent passwd "${REPO_OWNER}" 2>/dev/null | cut -d: -f6 || echo "/home/${REPO_OWNER}")"
KUBECONFIG="${REPO_OWNER_HOME}/.kube/config"

cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=PaaS lab recover after boot (postgres + schema check + env)
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
User=${REPO_OWNER}
Group=${REPO_OWNER}
WorkingDirectory=${REPO}
Environment=HOME=${REPO_OWNER_HOME}
Environment=KUBECONFIG=${KUBECONFIG}
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash ${RECOVER}
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable paas-lab-recover.service

if systemctl list-unit-files k3s.service >/dev/null 2>&1; then
  systemctl enable k3s.service 2>/dev/null || true
  echo "OK: k3s.service enabled on boot"
fi

echo ""
echo "Installed ${UNIT_PATH}"
echo "  REPO=${REPO}"
echo "  User=${REPO_OWNER}"
echo "  KUBECONFIG=${KUBECONFIG}"
echo ""
echo "Test now (no reboot):"
echo "  sudo systemctl start paas-lab-recover"
echo "  systemctl status paas-lab-recover --no-pager"
echo ""
echo "After reboot (~2–5 min): http://192.168.56.129:30100/login"
