#!/usr/bin/env bash
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=== Pod status (Unreachable usually = not Running) ==="
for ns in monitoring devtools security harbor; do
  echo "--- namespace ${ns} ---"
  kubectl get pods -n "${ns}" -o wide 2>/dev/null | head -25 || echo "(namespace missing)"
done

echo ""
echo "=== NodePorts (lab defaults) ==="
kubectl get svc -A 2>/dev/null | grep -iE 'trivy|grafana|elastic|nexus|artifactory|zap|pushgateway' || true

echo ""
echo "=== Probe from PaaS frontend pod ==="
if ! kubectl get deploy frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "frontend deployment not found in ${PAAS_NS}"
  exit 0
fi

probe_one() {
  local name="$1"
  local url="$2"
  if kubectl exec -n "${PAAS_NS}" deploy/frontend -- wget -q -O- -T 5 "${url}" 2>/dev/null | head -c 1 >/dev/null; then
    echo "OK   ${name}  ${url}"
  else
    echo "FAIL ${name}  ${url}"
  fi
}

probe_one "Grafana" "http://${NODE_IP}:32383/api/health"
probe_one "Grafana-alt" "http://${NODE_IP}:30082/api/health"
probe_one "Elasticsearch (in-cluster)" "http://elasticsearch-master.monitoring.svc.cluster.local:9200/_cluster/health"
probe_one "Elasticsearch (NodePort)" "http://${NODE_IP}:32231/_cluster/health"
probe_one "Nexus" "http://${NODE_IP}:31566/"
probe_one "Artifactory" "http://${NODE_IP}:31754/artifactory/api/system/ping"
probe_one "ZAP" "http://${NODE_IP}:32629/"
probe_one "Trivy (standalone NodePort)" "http://${NODE_IP}:30954/healthz"
probe_one "Pushgateway" "http://${NODE_IP}:31481/-/healthy"
probe_one "Harbor-Trivy" "http://harbor-trivy.harbor.svc.cluster.local:8080/api/v1/metadata"

echo ""
echo "=== Missing workloads (Services without pods) ==="
for ns in devtools monitoring security; do
  while read -r svc; do
    [[ -z "${svc}" ]] && continue
  pods="$(kubectl get pods -n "${ns}" -l "app.kubernetes.io/instance=${svc}" --no-headers 2>/dev/null | wc -l)"
  if [[ "${pods}" -eq 0 ]]; then
    any="$(kubectl get endpoints "${svc}" -n "${ns}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -z "${any}" ]]; then
      echo "  ${ns}/${svc}: no ready endpoints"
    fi
  fi
  done < <(kubectl get svc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
done

echo ""
echo "If FAIL: install or restart the Helm release for that tool."
echo "devtools empty => Nexus/Artifactory never deployed (only stale Services remain)."
