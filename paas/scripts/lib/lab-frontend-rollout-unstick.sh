#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"

echo "==> frontend rollout unstick (${PAAS_NS})"
kubectl get pods -n "${PAAS_NS}" -l app=frontend -o wide 2>/dev/null || true
kubectl get rs -n "${PAAS_NS}" -l app=frontend 2>/dev/null || true

echo "==> Force-remove frontend pods (including Terminating)"
for p in $(kubectl get pods -n "${PAAS_NS}" -l app=frontend -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  kubectl patch pod "${p}" -n "${PAAS_NS}" -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
  kubectl delete pod "${p}" -n "${PAAS_NS}" --force --grace-period=0 2>/dev/null || true
done

echo "==> Scale to 0 then back to 1 (Recreate — avoids maxUnavailable hang)"
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
sleep 3
kubectl get pods -n "${PAAS_NS}" -l app=frontend -o name 2>/dev/null | xargs -r kubectl delete -n "${PAAS_NS}" --force --grace-period=0 2>/dev/null || true
kubectl get pods -n "${PAAS_NS}" --field-selector=status.phase=Failed -o name 2>/dev/null | xargs -r kubectl delete -n "${PAAS_NS}" --force --grace-period=0 2>/dev/null || true
kubectl wait --for=delete pod -n "${PAAS_NS}" -l app=frontend --timeout=120s 2>/dev/null || true

kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {"op":"remove","path":"/spec/strategy/rollingUpdate"},
  {"op":"replace","path":"/spec/strategy/type","value":"Recreate"},
  {"op":"replace","path":"/spec/replicas","value":1}
]' 2>/dev/null || kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {"op":"replace","path":"/spec/strategy","value":{"type":"Recreate"}},
  {"op":"replace","path":"/spec/replicas","value":1}
]'

kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
kubectl get pods -n "${PAAS_NS}" -l app=frontend -o wide
