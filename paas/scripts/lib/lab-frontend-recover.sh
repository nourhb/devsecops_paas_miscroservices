#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PIN_MASTER="${PAAS_FRONTEND_PIN_MASTER:-0}"

echo "=============================================="
echo " lab-frontend-recover — Harbor + image + rollout"
echo "=============================================="

IMG="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ -z "${IMG}" ]]; then
  echo "ERROR: deployment/frontend not found in ${PAAS_NS}" >&2
  exit 1
fi
echo "==> Target image: ${IMG}"

if ! command -v docker >/dev/null 2>&1 || ! docker image inspect "${IMG}" >/dev/null 2>&1; then
  echo "ERROR: ${IMG} not in local docker on this host — build on master first:" >&2
  echo "  bash paas/scripts/lab.sh frontend" >&2
  exit 1
fi

echo "==> Preload image on master containerd"
docker save "${IMG}" | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true

HC="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30002/v2/" 2>/dev/null || echo 000)"
if [[ "${HC}" != "200" && "${HC}" != "401" ]]; then
  echo "WARN: Harbor /v2/ HTTP ${HC} — skipping push; pin frontend to master or import workers via ssh pipe"
  PIN_MASTER=1
  bash "${SCRIPT_DIR}/lab-harbor.sh" recover 2>/dev/null || true
else
  echo "==> Harbor OK (HTTP ${HC}) — push + preload workers"
  HARBOR_USER="${HARBOR_USER:-admin}"
  HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
  echo "${HARBOR_PASS}" | docker login "${NODE_IP}:30002" -u "${HARBOR_USER}" --password-stdin 2>/dev/null || true
  docker push "${IMG}" 2>/dev/null || PIN_MASTER=1
  bash "${SCRIPT_DIR}/lab-k3s-import-image-nodes.sh" "${IMG}" 2>/dev/null || PIN_MASTER=1
fi

echo "==> Stop rollout storm + remove evicted frontend pods"
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
sleep 3
kubectl get pods -n "${PAAS_NS}" -l app=frontend -o name 2>/dev/null | xargs -r kubectl delete -n "${PAAS_NS}" --force --grace-period=0 2>/dev/null || true
kubectl get pods -n "${PAAS_NS}" --field-selector=status.phase=Failed -o name 2>/dev/null | xargs -r kubectl delete -n "${PAAS_NS}" --force --grace-period=0 2>/dev/null || true

kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {"op":"remove","path":"/spec/strategy/rollingUpdate"},
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"},
  {"op":"replace","path":"/spec/replicas","value":1}
]' 2>/dev/null || true

if [[ "${PIN_MASTER}" == "1" ]]; then
  echo "==> Schedule frontend on master (image local; tolerates disk-pressure)"
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: master
      tolerations:
      - key: node.kubernetes.io/disk-pressure
        operator: Exists
        effect: NoSchedule
      containers:
      - name: frontend
        image: ${IMG}
        imagePullPolicy: IfNotPresent
PATCH
)"
else
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
spec:
  template:
    spec:
      nodeSelector: null
      containers:
      - name: frontend
        image: ${IMG}
        imagePullPolicy: IfNotPresent
PATCH
)"
fi

kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s || true
kubectl get pods -n "${PAAS_NS}" -l app=frontend -o wide
bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true
