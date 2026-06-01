#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RECOVER="${REPO}/paas/scripts/recover-paas-after-k3s-restart.sh"
UNIT_PATH="/etc/systemd/system/paas-lab-recover.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run: cd ~/devsecops_paas_miscroservices && sudo bash paas/scripts/fix-paas-autostart-unit-lab.sh" >&2
  exit 1
fi

if [[ ! -f "${RECOVER}" ]]; then
  echo "ERROR: not found: ${RECOVER}" >&2
  exit 1
fi

REPO_OWNER="$(stat -c '%U' "${REPO}" 2>/dev/null || echo master)"
REPO_OWNER_HOME="$(getent passwd "${REPO_OWNER}" 2>/dev/null | cut -d: -f6 || echo "/home/${REPO_OWNER}")"

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
Environment=KUBECONFIG=${REPO_OWNER_HOME}/.kube/config
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash ${RECOVER}
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable paas-lab-recover.service
systemctl enable k3s.service 2>/dev/null || true

echo "OK: ${UNIT_PATH}"
grep -E '^User=|^WorkingDirectory=|^ExecStart=' "${UNIT_PATH}"
echo ""
echo "Test: sudo systemctl start paas-lab-recover && systemctl status paas-lab-recover --no-pager"
