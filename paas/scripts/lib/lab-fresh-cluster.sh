#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
IMG="${IMG:-docker.io/library/paas-frontend:recovery}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'

LAB_DIR="${REPO_ROOT}/paas/k8s-manifests/lab"
HOSTED_FRONTEND="${REPO_ROOT}/paas/k8s-manifests/hosted/frontend.yaml"

log() { echo "[fresh-cluster] $*"; }
die() { log "ERROR: $*"; exit 1; }

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export PAAS_FORCE_KYVERNO_UNBLOCK=1

lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true

if ! systemctl is-active k3s >/dev/null 2>&1; then
  die "k3s not active — run: sudo systemctl start k3s && sleep 120"
fi

log "wait for API"
lab_k8s_api_wait || die "k8s API not ready"

NODES="$(k3s kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${NODES}" -eq 0 ]]; then
  log "WARN: no Node objects — waiting 60s (fresh k3s may still register master)"
  sleep 60
  NODES="$(k3s kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
fi
k3s kubectl get nodes -o wide 2>/dev/null || true
[[ "${NODES}" -ge 1 ]] || die "no k8s nodes — check: sudo journalctl -u k3s -n 40 --no-pager"

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo 0)"
log "disk ${DISK_PCT}%"
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 88 ]]; then
  die "disk ${DISK_PCT}%
fi

log "1/7 namespace + RBAC"
k3s kubectl apply --validate=false -f "${LAB_DIR}/namespace.yaml"
k3s kubectl apply --validate=false -f "${LAB_DIR}/paas-frontend-k8s-rbac.yaml"

log "2/7 postgres (PVC keeps data if PV still on disk)"
bash "${SCRIPT_DIR}/lab-postgres.sh" deploy
bash "${SCRIPT_DIR}/lab-postgres.sh" wait

log "3/7 prisma schema (User table)"
bash "${SCRIPT_DIR}/lab-postgres.sh" schema

log "4/7 frontend deployment + NodePort :30100"
[[ -f "${HOSTED_FRONTEND}" ]] || die "missing ${HOSTED_FRONTEND}"
k3s kubectl apply --validate=false -f "${HOSTED_FRONTEND}"
k3s kubectl apply --validate=false -f "${LAB_DIR}/frontend-nodeport.yaml"

log "5/7 env secret"
if [[ -f "${ENV_FILE}" ]]; then
  bash "${SCRIPT_DIR}/compose-paas-frontend-env.sh" 2>/dev/null || true
  PAAS_SKIP_ROLLOUT=1 ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || {
    log "env sync failed — creating minimal secret"
    k3s kubectl create secret generic paas-frontend-env -n "${PAAS_NS}" \
      --from-literal=DATABASE_URL="${DB_URL}" \
      --from-literal=KUBERNETES_ENABLED=true \
      --from-literal=NODE_IP="${NODE_IP}" \
      --dry-run=client -o yaml | k3s kubectl apply -f -
  }
else
  log "WARN: ${ENV_FILE} missing — minimal secret only"
  k3s kubectl create secret generic paas-frontend-env -n "${PAAS_NS}" \
    --from-literal=DATABASE_URL="${DB_URL}" \
    --from-literal=KUBERNETES_ENABLED=true \
    --from-literal=NODE_IP="${NODE_IP}" \
    --dry-run=client -o yaml | k3s kubectl apply -f -
fi

log "6/7 busybox + recovery image"
if ! k3s crictl images 2>/dev/null | grep -q 'busybox.*1.36'; then
  docker pull busybox:1.36 2>/dev/null || true
  docker save busybox:1.36 2>/dev/null | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
fi
if ! k3s crictl images 2>/dev/null | grep -qE 'paas-frontend.*recovery'; then
  if ! sudo k3s crictl images 2>/dev/null | grep -qE 'paas-frontend.*recovery'; then
    die "paas-frontend:recovery not in containerd (long build)"
  fi
fi

log "7/7 pin frontend on master (recovery image, Never pull)"
PAAS_FORCE_KYVERNO_UNBLOCK=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true
bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh"

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 12 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
log "login HTTP ${HTTP}"
bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true

if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
  log "OK — http://${NODE_IP}:30100/login"
  exit 0
fi

die "bootstrap finished but UI HTTP ${HTTP} — paste: k3s kubectl get pods,svc -n paas -o wide"
