#!/usr/bin/env bash
set -euo pipefail
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "==> Prometheus / operator pods in ${MON_NS}"
kubectl get pods -n "${MON_NS}" -o wide 2>/dev/null | grep -iE 'prometheus|operator|alertmanager|grafana' || \
  kubectl get pods -n "${MON_NS}" 2>/dev/null | head -20 || true

echo "==> Service endpoints (prometheus*)"
kubectl get endpoints -n "${MON_NS}" 2>/dev/null | grep -i prometheus || echo "WARN: no prometheus endpoints"

echo "==> Prometheus operator CRs"
kubectl get prometheus -n "${MON_NS}" 2>/dev/null || true
kubectl get prometheusrule -n "${MON_NS}" 2>/dev/null | head -3 || true

restart_prometheus_workloads() {
  local kind name
  while IFS= read -r line; do
  kind="${line%%/*}"
  name="${line#*/}"
  [[ -z "${name}" ]] && continue
  echo "==> rollout restart ${kind}/${name}"
  kubectl rollout restart -n "${MON_NS}" "${kind}/${name}" 2>/dev/null || true
  done < <(
    kubectl get sts,deploy -n "${MON_NS}" -o name 2>/dev/null | grep -iE 'prometheus|kube-prometheus-stack-operator' || true
  )
}

restart_prometheus_workloads

echo "==> Wait up to 4 min for any prometheus* endpoint"
for i in $(seq 1 24); do
  for svc in kube-prometheus-stack-prometheus prometheus-service prometheus-operated; do
    ip="$(kubectl get endpoints -n "${MON_NS}" "${svc}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      echo "OK ${svc} endpoint ${ip}"
      if curl -fsS --connect-timeout 5 "http://${NODE_IP}:30536/-/ready" >/dev/null 2>&1; then
        echo "OK NodePort :30536 ready"
      elif curl -fsS --connect-timeout 5 "http://${NODE_IP}:30083/-/ready" >/dev/null 2>&1; then
        echo "OK NodePort :30083 ready"
      fi
      exit 0
    fi
  done
  sleep 10
done

echo "ERROR: Prometheus still has no endpoints in ${MON_NS}" >&2
echo "  Inspect: kubectl describe prometheus -n ${MON_NS}" >&2
echo "  Or reinstall: helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack -n ${MON_NS}" >&2
exit 1
