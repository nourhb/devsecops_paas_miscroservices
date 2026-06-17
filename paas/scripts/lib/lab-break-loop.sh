#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"

echo "=============================================="
echo " lab-break-loop — STOP auto-heal / rollout storms"
echo "=============================================="

echo "==> Remove auto-heal cron (watchdog/guard/db-repair)"
crontab -l 2>/dev/null | grep -vE 'paas/scripts/lab.sh|paas-lab-watchdog|paas-lab-guard|db-repair' | crontab - 2>/dev/null || true
echo "OK: cron cleared (run: bash paas/scripts/lab.sh guard-cron install after stable)"

echo "==> Kyverno webhooks (unblock kubectl)"
for w in $(kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -i kyverno || true); do
  kubectl delete "${w}" --ignore-not-found --wait=false
done
for w in $(kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -i kyverno || true); do
  kubectl delete "${w}" --ignore-not-found --wait=false
done

echo "==> Pause + scale down frontend (stops eviction / rollout loop)"
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
kubectl rollout pause deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false 2>/dev/null || true

echo "==> Do NOT restart postgres (break db-repair loop)"
touch /var/tmp/paas-lab-no-auto-heal 2>/dev/null || sudo touch /var/tmp/paas-lab-no-auto-heal 2>/dev/null || true
echo "$(date -Is 2>/dev/null || date)" > /var/tmp/paas-lab-no-auto-heal 2>/dev/null || \
  echo "$(date -Is 2>/dev/null || date)" | sudo tee /var/tmp/paas-lab-no-auto-heal >/dev/null

echo "==> Bulk delete Failed pods"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${ns}" == kube-* ]] && continue
  kubectl delete pods -n "${ns}" --field-selector=status.phase=Failed \
    --force --grace-period=0 --wait=false 2>/dev/null || true
done

sleep 2
echo ""
df -h / | tail -1
kubectl get nodes -o wide 2>/dev/null || true
kubectl get pods -n "${PAAS_NS}" -o wide 2>/dev/null || true
kubectl get endpoints postgres -n "${PAAS_NS}" 2>/dev/null || true
echo ""
echo "=============================================="
echo " LOOP STOPPED."
echo ""
echo " Next (manual, one step at a time — do NOT run db-repair in a loop):"
echo "   1. df -h /   # need < 85%"
echo "   2. kubectl get pods -n paas -l app=postgres -o wide"
echo "   3. kubectl describe pod -n paas -l app=postgres | tail -40"
echo "   4. When postgres has endpoints: kubectl exec -n paas deploy/postgres -- pg_isready"
echo "   5. bash paas/scripts/lab.sh frontend-heal   # or manual scale 1 + resume"
echo "=============================================="
