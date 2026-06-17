#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
IMG="${IMG:-192.168.56.129:30002/paas/frontend:local-20260617112005}"

echo "==> PaaS frontend minimal deploy (master, no registry pull)"
if ! docker image inspect "${IMG}" >/dev/null 2>&1; then
  echo "ERROR: ${IMG} not in docker on master" >&2
  exit 1
fi

docker save "${IMG}" | sudo k3s ctr -n k8s.io images import - 2>/dev/null || true

kubectl rollout resume deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {"op":"remove","path":"/spec/strategy/rollingUpdate"},
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"},
  {"op":"replace","path":"/spec/replicas","value":1}
]' 2>/dev/null || true

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
        imagePullPolicy: Never
PATCH
)"

sleep 15
kubectl get pods -n "${PAAS_NS}" -l app=frontend -o wide
POD="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${POD}" ]]; then
  kubectl describe pod -n "${PAAS_NS}" "${POD}" | tail -12
fi
curl -sS -o /dev/null -w 'UI HTTP %{http_code}\n' http://192.168.56.129:30100/api/health 2>/dev/null || true
