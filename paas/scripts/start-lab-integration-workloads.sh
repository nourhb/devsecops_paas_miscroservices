#!/usr/bin/env bash
set -euo pipefail

echo "=== Scale Grafana (was 0/0) ==="
kubectl scale deployment/grafana -n monitoring --replicas=1 2>/dev/null || true
kubectl scale deployment/kube-prometheus-stack-grafana -n monitoring --replicas=1 2>/dev/null || true

echo "=== Scale Pushgateway if present ==="
kubectl scale deployment -n monitoring -l app.kubernetes.io/name=prometheus-pushgateway --replicas=1 2>/dev/null \
  || kubectl scale deployment pushgateway-prometheus-pushgateway -n monitoring --replicas=1 2>/dev/null \
  || true

echo "=== Scale kube-prometheus operator / kube-state-metrics / prometheus if 0 ==="
kubectl scale deployment kube-prometheus-stack-operator -n monitoring --replicas=1 2>/dev/null || true
kubectl scale deployment kube-prometheus-stack-kube-state-metrics -n monitoring --replicas=1 2>/dev/null || true
kubectl scale statefulset prometheus-kube-prometheus-stack-prometheus -n monitoring --replicas=1 2>/dev/null || true

echo "=== ZAP (security) ==="
if kubectl get deploy zap -n security >/dev/null 2>&1; then
  kubectl scale deployment/zap -n security --replicas=1
elif kubectl get deploy -n security -o name 2>/dev/null | grep -qi zap; then
  kubectl get deploy -n security -o name | grep -i zap | xargs -r kubectl scale -n security --replicas=1
else
  echo "WARN: no ZAP deployment — only Service exists. Install ZAP or remove NEXT_PUBLIC_OWASP_ZAP_URL from env."
fi

echo "=== devtools (Nexus / Artifactory) — no pods in namespace ==="
if ! kubectl get pods -n devtools --no-headers 2>/dev/null | grep -q .; then
  echo "No pods in devtools. Stale Services only. Options:"
  echo "  A) Reinstall: helm list -n devtools  &&  helm upgrade --install ..."
  echo "  B) Remove from hub: kubectl delete ns devtools"
  echo "     then remove NEXT_PUBLIC_NEXUS_URL / ARTIFACTORY_URL from paas/frontend/docker-compose.env"
fi

echo ""
echo "=== Wait for rollouts (60s) ==="
kubectl rollout status deployment/kube-prometheus-stack-grafana -n monitoring --timeout=120s 2>/dev/null || true
kubectl rollout status deployment/grafana -n monitoring --timeout=120s 2>/dev/null || true

echo ""
echo "=== Status ==="
kubectl get deploy -n monitoring | grep -iE 'grafana|pushgateway' || true
kubectl get pods -n devtools 2>/dev/null || echo "devtools: no pods"
kubectl get pods -n security | grep -iE 'zap|trivy' || true

echo ""
echo "Then: bash paas/scripts/lab.sh integrations-diagnose"
echo "      Refresh Platform hub"
