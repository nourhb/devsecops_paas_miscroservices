#!/usr/bin/env bash
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=== Pod status (Unreachable usually = not Running) ==="
for ns in monitoring devtools security harbor; do
  echo "--- namespace ${ns} ---"
  kubectl get pods -n "${ns}" -o wide 2>/dev/null | head -20 || echo "(namespace missing)"
done

echo ""
echo "=== NodePorts (lab defaults) ==="
kubectl get svc -A 2>/dev/null | grep -iE 'trivy|grafana|elastic|nexus|artifactory|zap|pushgateway' || true

echo ""
echo "=== Probe from PaaS frontend pod ==="
if kubectl get deploy frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  for label port path in \
    "Grafana:${NODE_IP}:32383:/api/health" \
    "Elasticsearch:${NODE_IP}:32231:/" \
    "Nexus:${NODE_IP}:31566:/" \
    "Artifactory:${NODE_IP}:31754:/artifactory/api/system/ping" \
    "ZAP:${NODE_IP}:32629:/" \
    "Trivy:${NODE_IP}:30954:/healthz" \
    "Pushgateway:${NODE_IP}:31481:/-/healthy"; do
    name="${label%%:*}"
    rest="${label#*:}"
    hostport="${rest%%:*}"
    probe_path="${rest#*:}"
    kubectl exec -n "${PAAS_NS}" deploy/frontend -- wget -q -O- -T 4 "http://${hostport}${probe_path}" 2>/dev/null \
      && echo "OK ${name}" || echo "FAIL ${name} http://${hostport}${probe_path}"
  done
else
  echo "frontend deployment not found in ${PAAS_NS}"
fi

echo ""
echo "If FAIL: kubectl describe pod -n <ns> <pod>  then fix CrashLoop/ImagePull or scale up Helm release."
