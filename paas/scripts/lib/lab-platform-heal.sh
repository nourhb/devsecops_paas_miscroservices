#!/usr/bin/env bash
# One command after k3s is started: git sync → quick-up → Sonar → Jenkins CPS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
cd "${REPO_ROOT}"

log() { echo "==> $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

log "1/6 k3s API"
if ! systemctl is-active k3s >/dev/null 2>&1; then
  log "k3s not active — start/restart (needs sudo)"
  sudo systemctl start k3s 2>/dev/null || sudo systemctl restart k3s
  sleep 90
fi
if ! bash "${SCRIPT_DIR}/lab-k3s-ensure.sh"; then
  log "k3s-ensure failed — vacuum SQLite (sudo)"
  sudo bash "${SCRIPT_DIR}/lab-k3s-db-vacuum.sh" || true
  sleep 30
  bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || die "k3s still down — sudo journalctl -u k3s -n 40 --no-pager"
fi

log "2/6 git pull (discard VM-local edits on lab scripts)"
for f in \
  paas/scripts/lib/fix-paas-deploy-cps-split-now.sh \
  paas/scripts/lib/lab-sonarqube-fresh-install.sh \
  paas/scripts/lab.sh; do
  git checkout -- "${f}" 2>/dev/null || true
done
git pull

log "3/6 quick-up"
bash "${SCRIPT_DIR}/lab-quick-up.sh"

log "4/6 Sonar"
bash "${SCRIPT_DIR}/lab-sonarqube-fresh-install.sh"

log "5/6 Jenkins CPS split"
bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"

log "6/6 env sync"
bash "${SCRIPT_DIR}/../lab.sh" env-quick || true

echo ""
echo "=============================================="
echo "OK — platform heal done"
echo "  UI:      http://${NODE_IP}:30100"
echo "  Jenkins: http://${NODE_IP}:30090"
echo "  Sonar:   http://${NODE_IP}:30900"
echo "Trigger a NEW paas-deploy build (not Replay)."
echo "=============================================="
