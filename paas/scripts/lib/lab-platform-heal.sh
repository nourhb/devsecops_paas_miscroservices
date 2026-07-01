#!/usr/bin/env bash
# One command after k3s is started: git sync → quick-up → Sonar → Jenkins CPS.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
cd "${REPO_ROOT}"

# Line-buffered logs (avoid "silent for an hour" when stdout is not a TTY)
log() { echo "[$(date +%H:%M:%S)] ==> $*"; }
die() { echo "[$(date +%H:%M:%S)] FAIL: $*" >&2; exit 1; }

log "platform-heal start (Ctrl+C safe — re-run same command to resume)"

log "1/6 k3s API"
if ! systemctl is-active k3s >/dev/null 2>&1; then
  log "k3s not active — start once (sudo)"
  sudo systemctl start k3s 2>/dev/null || sudo systemctl restart k3s
  sleep 60
fi
export LAB_K3S_WAIT_LOOPS="${LAB_K3S_WAIT_LOOPS:-24}"
export LAB_K3S_WAIT_SEC="${LAB_K3S_WAIT_SEC:-5}"
if ! bash "${SCRIPT_DIR}/lab-k3s-ensure.sh"; then
  die "k3s API still down after ~$(( LAB_K3S_WAIT_LOOPS * LAB_K3S_WAIT_SEC ))s — run:

  sudo bash paas/scripts/lab.sh k3s-unstick

If journal shows Slow SQL / compact_rev_key:

  sudo bash paas/scripts/lab.sh k3s-vacuum"
fi

log "2/6 git pull"
for f in \
  paas/scripts/lib/fix-paas-deploy-cps-split-now.sh \
  paas/scripts/lib/lab-sonarqube-fresh-install.sh \
  paas/scripts/lib/lab-platform-heal.sh \
  paas/scripts/lab.sh; do
  git checkout -- "${f}" 2>/dev/null || true
done
git pull

log "3/6 quick-up"
bash "${SCRIPT_DIR}/lab-quick-up.sh"

if curl -fsS -m 8 "http://${NODE_IP}:${SONAR_NODEPORT:-30900}/api/system/status" 2>/dev/null \
  | grep -q '"status":"UP"'; then
  log "4/6 Sonar already UP — skip fresh install"
  SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false \
    bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" 2>/dev/null || true
else
  log "4/6 Sonar fresh install"
  bash "${SCRIPT_DIR}/lab-sonarqube-fresh-install.sh"
fi

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
