#!/usr/bin/env bash
# Start or restart k3s when API is unreachable (common after host PC reboot + VM start).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

if lab_k8s_api_ready; then
  echo "OK: k3s API already up"
  exit 0
fi

echo "WARN: k3s API not reachable — starting k3s.service"
if ! timeout 30 systemctl is-active k3s >/dev/null 2>&1; then
  timeout 60 sudo systemctl start k3s 2>/dev/null || sudo systemctl start k3s || true
fi
timeout 90 sudo systemctl restart k3s 2>/dev/null || sudo systemctl restart k3s || true

for i in $(seq 1 48); do
  if lab_k8s_api_ready; then
    echo "OK: k3s API ready (attempt ${i})"
    exit 0
  fi
  echo "  [${i}/48] waiting for k3s API…"
  sleep 5
done

echo "ERROR: k3s API still down after restart" >&2
echo "  sudo systemctl status k3s --no-pager" >&2
echo "  sudo journalctl -u k3s -n 40 --no-pager" >&2
exit 1
