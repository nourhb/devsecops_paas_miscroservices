#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONOREPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

kubectl apply -f "${MONOREPO_ROOT}/paas/k8s-manifests/lab/frontend-nodeport-service.yaml"

echo "=== Services in ${PAAS_NS} ==="
kubectl get svc -n "${PAAS_NS}" -o wide | grep -E 'NAME|frontend' || kubectl get svc -n "${PAAS_NS}"

echo "=== Endpoints ==="
kubectl get endpoints -n "${PAAS_NS}" frontend-service -o yaml 2>/dev/null | grep -E 'addresses:|ip:' || \
  echo "No endpoints on frontend-service"

for url in "http://127.0.0.1:30100/api/health" "http://${NODE_IP}:30100/api/health"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "${url}" 2>/dev/null || true)"
  code="${code:-000}"
  echo "${url} → HTTP ${code}"
done
