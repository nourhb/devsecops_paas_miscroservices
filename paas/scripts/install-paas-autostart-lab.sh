#!/usr/bin/env bash
set -euo pipefail

REPO="${PAAS_REPO:-$HOME/devsecops_paas_miscroservices}"
UNIT_PATH="/etc/systemd/system/paas-lab-recover.service"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Run with sudo: sudo bash paas/scripts/install-paas-autostart-lab.sh"
  exit 1
fi

cat > "${UNIT_PATH}" <<EOF
[Unit]
Description=PaaS lab recover after boot (postgres + schema check + env)
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${REPO}
ExecStart=/bin/bash ${REPO}/paas/scripts/recover-paas-after-k3s-restart.sh
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable paas-lab-recover.service
echo "Enabled. After reboot: systemctl status paas-lab-recover"
echo "Does NOT re-seed users — only starts DB and applies schema if tables are missing."
