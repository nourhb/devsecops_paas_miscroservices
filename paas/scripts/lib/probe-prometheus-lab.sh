#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "==> Prometheus lab probe"
kubectl get svc -n "${MON_NS}" 2>/dev/null | grep -i prometheus || true
echo "==> Endpoints"
kubectl get endpoints -n "${MON_NS}" 2>/dev/null | grep -i prometheus || echo "WARN: no prometheus endpoints"
kubectl get pods -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|operator' || echo "WARN: no prometheus pods"

frontend_pod() {
  kubectl get pods -n "${PAAS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -E '^frontend-|^paas-frontend-' | grep -v Terminating | head -1 || true
}

echo "==> Direct in-cluster wget from frontend pod"
FP="$(frontend_pod)"
if [[ -n "${FP}" ]]; then
  for url in \
    "http://kube-prometheus-stack-prometheus.${MON_NS}.svc:9090/-/ready" \
    "http://prometheus-service.${MON_NS}.svc:9090/-/ready" \
    "http://prometheus-operated.${MON_NS}.svc:9090/-/ready" \
    "http://${NODE_IP}:30536/-/ready" \
    "http://${NODE_IP}:30083/-/ready"; do
    if kubectl exec -n "${PAAS_NS}" "${FP}" -- wget -qO- -T 8 "${url}" 2>/dev/null | grep -qi ready; then
      echo "OK ${url}"
      exit 0
    fi
    echo "WARN failed ${url}"
  done
else
  echo "WARN: no frontend pod in ${PAAS_NS}"
fi

echo "==> Kubernetes API service proxy"
for svc in kube-prometheus-stack-prometheus prometheus-service prometheus-operated; do
  raw="/api/v1/namespaces/${MON_NS}/services/http:${svc}:9090/proxy/-/ready"
  if out="$(kubectl get --raw "${raw}" 2>/dev/null)" && echo "${out}" | grep -qi ready; then
    echo "OK k8s proxy ${svc}"
    exit 0
  fi
  err="$(kubectl get --raw "${raw}" 2>&1 || true)"
  echo "WARN ${svc}: ${err##*$'\n'}"
done

echo ""
echo "Prometheus is down or has no endpoints. Run:"
echo "  bash paas/scripts/lib/lab-prometheus-recover.sh"
exit 1
