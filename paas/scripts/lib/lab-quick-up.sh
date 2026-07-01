#!/usr/bin/env bash
# ONE command lab recovery — short timeouts, no scale-to-0 storms, no Harbor/bootstrap.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
IMG="${IMG:-docker.io/library/paas-frontend:recovery}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'
if [[ "${PAAS_BOOT_RECOVER:-}" == "1" ]]; then
  MAX_API_TRIES=24
else
  MAX_API_TRIES=12
fi
API_TIMEOUT=15

log() { echo "[quick-up] $*"; }
fail() { log "FAIL: $*"; exit 1; }

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export PAAS_FORCE_KYVERNO_UNBLOCK=1

lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
chmod +x "${REPO_ROOT}/paas/scripts/lab.sh" "${SCRIPT_DIR}"/*.sh 2>/dev/null || true

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}' || echo 0)"
log "disk ${DISK_PCT}%"
df -h / | tail -1
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 88 ]]; then
  fail "disk ${DISK_PCT}% — run: bash paas/scripts/lab.sh disk-emergency"
fi

if systemctl is-active k3s >/dev/null 2>&1; then
  log "k3s active"
elif systemctl is-failed k3s >/dev/null 2>&1 || ! systemctl is-enabled k3s >/dev/null 2>&1; then
  log "k3s not running — start once (needs sudo password)"
  sudo systemctl start k3s
  sleep 60
else
  log "k3s is activating — wait up to 5 min (do NOT restart again)"
  for i in $(seq 1 30); do
    systemctl is-active k3s >/dev/null 2>&1 && { log "k3s active (${i})"; break; }
    echo "  …activating ${i}/30"
    sleep 10
  done
fi
systemctl is-active k3s >/dev/null 2>&1 || fail "k3s not active — run: sudo journalctl -u k3s -n 30 --no-pager"

api_try() {
  k3s kubectl "$@" --request-timeout="${API_TIMEOUT}s" 2>/dev/null
}

log "wait for API (max ${MAX_API_TRIES} x ${API_TIMEOUT}s)"
API_OK=0
for i in $(seq 1 "${MAX_API_TRIES}"); do
  if api_try get nodes >/dev/null; then
    API_OK=1
    log "API OK (attempt ${i})"
    break
  fi
  echo "  …${i}/${MAX_API_TRIES}"
  sleep 8
done
[[ "${API_OK}" -eq 1 ]] || fail "k3s API down — wait 5 min after last restart, then: sudo systemctl restart k3s && sleep 120"

if ! api_try get namespace "${PAAS_NS}" >/dev/null 2>&1; then
  log "namespace ${PAAS_NS} missing — run full bootstrap"
  bash "${SCRIPT_DIR}/lab-fresh-cluster.sh"
  exit $?
fi

api_try get nodes -o wide || true

api_try taint nodes master node.kubernetes.io/unreachable:NoExecute- 2>/dev/null || true
api_try taint nodes master node.kubernetes.io/unreachable:NoSchedule- 2>/dev/null || true

# Master must be Ready (frontend image is local on master only)
MASTER_READY="$(api_try get node master -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || echo False)"
if [[ "${MASTER_READY}" != "True" ]]; then
  log "master NotReady — clear taints only (no k3s restart)"
  api_try taint nodes master node.kubernetes.io/disk-pressure:NoSchedule- || true
  api_try taint nodes master node.kubernetes.io/memory-pressure:NoSchedule- || true
  for i in $(seq 1 12); do
    MASTER_READY="$(api_try get node master -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || echo False)"
    [[ "${MASTER_READY}" == "True" ]] && break
    sleep 10
  done
fi
[[ "${MASTER_READY}" == "True" ]] || fail "master still NotReady — check: k3s kubectl describe node master"

# Kyverno fail-open (fast)
[[ -f "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" ]] && \
  PAAS_FORCE_KYVERNO_UNBLOCK=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true

# Postgres — light check only
if ! api_try exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1; then
  log "postgres not ready — db-repair once"
  PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
fi

# busybox for init container (if missing)
if ! k3s crictl images 2>/dev/null | grep -q 'busybox.*1.36'; then
  log "import busybox:1.36"
  docker pull busybox:1.36 2>/dev/null || true
  docker save busybox:1.36 2>/dev/null | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
fi

# Recovery image must be in containerd
if ! k3s crictl images 2>/dev/null | grep -qE 'paas-frontend.*recovery'; then
  fail "paas-frontend:recovery missing — run: bash paas/scripts/lab.sh frontend (30 min build)"
fi
log "recovery image present"

# Patch frontend IN PLACE — never scale to 0 first
log "patch frontend (Recreate, master, replicas=1)"
api_try patch deployment frontend -n "${PAAS_NS}" --type=merge -p "$(cat <<PATCH
{
  "spec": {
    "replicas": 1,
    "revisionHistoryLimit": 0,
    "strategy": {"type": "Recreate"},
    "template": {
      "spec": {
        "nodeSelector": {"kubernetes.io/hostname": "master"},
        "tolerations": [{
          "key": "node.kubernetes.io/disk-pressure",
          "operator": "Exists",
          "effect": "NoSchedule"
        }],
        "initContainers": [{
          "name": "wait-postgres",
          "image": "busybox:1.36",
          "imagePullPolicy": "IfNotPresent",
          "command": ["sh", "-c", "until nc -z postgres 5432; do sleep 3; done"]
        }],
        "containers": [{
          "name": "frontend",
          "image": "${IMG}",
          "imagePullPolicy": "Never",
          "env": [{"name": "DATABASE_URL", "value": "${DB_URL}"}]
        }]
      }
    }
  }
}
PATCH
)" || fail "could not patch frontend — API too slow; wait 2 min and re-run: bash paas/scripts/lab.sh quick-up"

log "wait for frontend pod (max 3 min)"
for i in $(seq 1 18); do
  READY="$(api_try get pods -n "${PAAS_NS}" -l app=frontend \
    -o jsonpath='{.items[0].status.containerStatuses[0].ready}' || echo false)"
  [[ "${READY}" == "true" ]] && break
  sleep 10
done
api_try get pods -n "${PAAS_NS}" -l app=frontend -o wide || true

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
log "login HTTP ${HTTP}"

if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
  log "OK — http://${NODE_IP}:30100/login"
  api_try set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" --containers=frontend 2>/dev/null || true
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh" 2>/dev/null || true
  exit 0
fi

log "UI not up — env sync + db-repair once"
PAAS_SKIP_ROLLOUT=1 bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" 2>/dev/null || true
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
  log "OK — http://${NODE_IP}:30100/login"
  exit 0
fi

fail "UI still HTTP ${HTTP} — paste: k3s kubectl get pods -n paas -o wide && k3s kubectl describe pod -n paas -l app=frontend | tail -30"
