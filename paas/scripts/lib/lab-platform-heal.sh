#!/usr/bin/env bash
# Lab script to platform heal on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
cd "${REPO_ROOT}"

log() { echo "[$(date +%H:%M:%S)] ==> $*"; }
die() { echo "[$(date +%H:%M:%S)] FAIL: $*" >&2; exit 1; }

log "platform-heal start (Ctrl+C safe — re-run same command to resume)"

log "1/7 k3s API"
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

log "2/7 git pull"
for f in \
  paas/scripts/lib/fix-paas-deploy-cps-split-now.sh \
  paas/scripts/lib/lab-sonarqube-fresh-install.sh \
  paas/scripts/lib/lab-platform-heal.sh \
  paas/scripts/lab.sh; do
  git checkout -- "${f}" 2>/dev/null || true
done
git pull

source "${SCRIPT_DIR}/lab-kube-env.sh"
lab_ensure_kubeconfig || true
if lab_worker_notready worker2 2>/dev/null; then
  log "worker2 NotReady before quick-up — heal Postgres PVC node"
  bash "${SCRIPT_DIR}/lab-worker2-heal.sh" || log "WARN: worker2 still NotReady — postgres/Jenkins may fail"
fi

log "3/7 quick-up"
bash "${SCRIPT_DIR}/lab-quick-up.sh"

log "4/7 Dependency-Track"
if curl -fsS -m 5 "http://${NODE_IP}:32336/api/version" 2>/dev/null | grep -q '"version"'; then
  log "Dependency-Track already UP on :32336"
  LAB_DT_ENV_ONLY=true bash "${SCRIPT_DIR}/lab-dependency-track.sh" 2>/dev/null || true
else
  bash "${SCRIPT_DIR}/lab-dependency-track.sh" || log "WARN: dependency-track heal failed — Step 4 may WARN until fixed"
fi

if curl -fsS -m 8 "http://${NODE_IP}:${SONAR_NODEPORT:-30900}/api/system/status" 2>/dev/null \
  | grep -q '"status":"UP"'; then
  log "5/7 Sonar already UP — skip fresh install"
  SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false \
    bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" 2>/dev/null || true
else
  log "5/7 Sonar fresh install"
  bash "${SCRIPT_DIR}/lab-sonarqube-fresh-install.sh"
fi

log "6/7 Jenkins CPS split"
export PAAS_DT_UPLOAD_OPTIONAL="${PAAS_DT_UPLOAD_OPTIONAL:-true}"
bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"

log "7/7 env sync"
bash "${SCRIPT_DIR}/../lab.sh" env-quick || true

echo ""
echo "=============================================="
echo "OK — platform heal done"
echo "  UI:      http://${NODE_IP}:30100"
echo "  Jenkins: http://${NODE_IP}:30090"
echo "  Sonar:   http://${NODE_IP}:30900"
echo "  DT API:  http://${NODE_IP}:32336/api/version"
echo "Trigger a NEW paas-deploy build (not Replay)."
echo "=============================================="
