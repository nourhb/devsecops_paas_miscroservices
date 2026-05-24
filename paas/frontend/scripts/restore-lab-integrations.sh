#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=== NodePorts (verify against frontend/.env) ==="
kubectl get svc -A -o wide 2>/dev/null | grep -E 'NodePort|NAMESPACE|harbor|grafana|prometheus|alertmanager|trivy|sonar|jenkins|pushgateway|traefik|elasticsearch|kibana|zap' || true

echo "=== Scale core integrations (one namespace at a time; skip if OOM) ==="
kubectl scale deployment -n cicd jenkins --replicas=1 2>/dev/null || true
kubectl scale deployment -n sonarqube --all --replicas=1 2>/dev/null || true
kubectl scale deployment -n security --all --replicas=1 2>/dev/null || true

kubectl scale statefulset -n harbor harbor-database harbor-redis --replicas=1 2>/dev/null || true
kubectl scale deployment -n harbor harbor-core harbor-portal harbor-registry harbor-jobservice harbor-nginx --replicas=1 2>/dev/null || true

kubectl scale statefulset -n monitoring alertmanager-kube-prometheus-stack-alertmanager prometheus-kube-prometheus-stack-prometheus --replicas=1 2>/dev/null || true
kubectl scale deployment -n monitoring kube-prometheus-stack-grafana kube-prometheus-stack-operator --replicas=1 2>/dev/null || true
kubectl scale statefulset -n monitoring elasticsearch-master --replicas=1 2>/dev/null || true

echo "=== Wait for key pods (timeout 5m each) ==="
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=grafana -n monitoring --timeout=300s 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=harbor,component=core -n harbor --timeout=300s 2>/dev/null || true

echo "=== Quick probes from host ==="
for url in \
  "http://${NODE_IP}:30659/" \
  "http://${NODE_IP}:32383/api/health" \
  "http://${NODE_IP}:30536/-/ready" \
  "http://${NODE_IP}:30772/-/healthy" \
  "http://${NODE_IP}:30954/healthz" \
  "http://${NODE_IP}:30086/api/system/status" \
  "http://${NODE_IP}:30090/login" \
  "http://${NODE_IP}:30002/api/v2.0/ping"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 "$url" 2>/dev/null || echo "000")
  echo "$code  $url"
done

echo "Done. Regenerate docker-compose.env and recreate frontend:"
echo "  cd ~/devsecops_paas_miscroservices/paas/frontend && python3 scripts/flatten-env-for-compose.py"
echo "  cd .. && docker compose up -d --force-recreate frontend"
