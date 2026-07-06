#!/usr/bin/env bash
# Lab script to reboot recover on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PG_IMAGE="${PG_IMAGE:-postgres:15-alpine}"
FE_IMAGE="${FE_IMAGE:-docker.io/library/paas-frontend:recovery}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'
PGDATA_HOST="${PGDATA_HOST:-/var/lib/rancher/k3s/storage/pvc-be491b65-d482-4d3e-9a4c-e645c1a2db23_paas_postgres-pvc/pgdata}"

log() { echo "[reboot-recover] $*"; }

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
export PAAS_FORCE_KYVERNO_UNBLOCK=1
lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true

if ! systemctl is-active k3s >/dev/null 2>&1; then
  log "starting k3s…"
  sudo systemctl start k3s
  sleep 45
fi
lab_k8s_api_wait || { log "k3s API not ready"; exit 1; }

log "import local images into containerd"
docker pull "${PG_IMAGE}" 2>/dev/null || true
docker save "${PG_IMAGE}" 2>/dev/null | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
if docker image inspect "${FE_IMAGE}" >/dev/null 2>&1; then
  docker save "${FE_IMAGE}" 2>/dev/null | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true
fi

log "re-apply postgres + frontend manifests"
kubectl apply --validate=false -f "${REPO_ROOT}/paas/k8s-manifests/lab/postgres-in-paas.yaml"
kubectl apply --validate=false -f "${REPO_ROOT}/paas/k8s-manifests/hosted/frontend.yaml"
if [[ -f "${REPO_ROOT}/paas/k8s-manifests/lab/frontend-nodeport.yaml" ]]; then
  kubectl apply --validate=false -f "${REPO_ROOT}/paas/k8s-manifests/lab/frontend-nodeport.yaml"
else
  kubectl patch svc frontend -n "${PAAS_NS}" --type=merge -p \
    '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":3000,"nodePort":30100}]}}' \
    2>/dev/null || true
fi

log "postgres ${PG_IMAGE} (lab data is PG15)"
kubectl set image deployment/postgres -n "${PAAS_NS}" postgres="${PG_IMAGE}"
kubectl patch deployment postgres -n "${PAAS_NS}" --type=json -p='[
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"},
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}
]' 2>/dev/null || true

if [[ -d "${PGDATA_HOST}" ]] && [[ -f "${PGDATA_HOST}/postmaster.pid" ]]; then
  log "remove stale postmaster.pid"
  kubectl scale deployment/postgres -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
  sleep 10
  sudo rm -f "${PGDATA_HOST}/postmaster.pid"
  sudo chown -R 70:70 "${PGDATA_HOST}"
  kubectl scale deployment/postgres -n "${PAAS_NS}" --replicas=1
fi

log "wait for postgres"
for i in $(seq 1 36); do
  if kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1; then
    log "postgres ready"
    break
  fi
  if [[ "${i}" -eq 6 || "${i}" -eq 18 ]]; then
    kubectl logs -n "${PAAS_NS}" -l app=postgres --tail=15 2>/dev/null || true
  fi
  sleep 5
done

log "frontend recovery image on master"
kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {"op":"remove","path":"/spec/strategy/rollingUpdate"},
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"}
]' 2>/dev/null || true
kubectl set image deployment/frontend -n "${PAAS_NS}" frontend="${FE_IMAGE}"
kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {"op":"replace","path":"/spec/replicas","value":1},
  {"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"Never"},
  {"op":"replace","path":"/spec/template/spec/nodeSelector","value":{"kubernetes.io/hostname":"master"}}
]' 2>/dev/null || true
kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" --containers=frontend 2>/dev/null || true

kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false 2>/dev/null || true
kubectl delete pods -n "${PAAS_NS}" -l app=postgres --field-selector=status.phase=Failed --force --grace-period=0 2>/dev/null || true

sleep 20
kubectl get pods -n "${PAAS_NS}" -o wide || true

HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${NODE_IP}:30100/login" 2>/dev/null || echo 000)"
log "login HTTP ${HTTP}"
bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true

if [[ "${HTTP}" =~ ^(200|307|308)$ ]]; then
  log "OK — http://${NODE_IP}:30100/login"
  exit 0
fi

log "still failing — run: k3s kubectl logs -n paas -l app=postgres --tail=40"
exit 1
