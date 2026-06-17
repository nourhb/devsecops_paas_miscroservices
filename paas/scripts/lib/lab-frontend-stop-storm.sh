#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"

echo "==> STOP frontend pod storm (${PAAS_NS})"

kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
kubectl rollout pause deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl scale rs -n "${PAAS_NS}" -l app=frontend --replicas=0 2>/dev/null || true
kubectl get rs -n "${PAAS_NS}" -l app=frontend -o name 2>/dev/null | while read -r rs; do
  kubectl scale "${rs}" -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
done

echo "==> Bulk delete frontend pods (background — do not wait for each pod)"
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false 2>/dev/null || true
kubectl delete pods -n "${PAAS_NS}" --field-selector=status.phase=Failed --force --grace-period=0 --wait=false 2>/dev/null || true

sleep 3
LEFT="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "frontend pods remaining: ${LEFT} (Terminating pods clear in background)"
echo "OK: storm stopped — fix disk before: kubectl scale deployment/frontend -n ${PAAS_NS} --replicas=1"
