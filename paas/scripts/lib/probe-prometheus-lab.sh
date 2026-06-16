#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PROM_SVC="${PROMETHEUS_K8S_SERVICE:-kube-prometheus-stack-prometheus}"

echo "==> Prometheus lab probe"
kubectl get svc -n "${MON_NS}" "${PROM_SVC}" prometheus-service 2>/dev/null | sed -n '1,4p' || true
kubectl get endpoints -n "${MON_NS}" "${PROM_SVC}" -o wide 2>/dev/null || true

echo "==> Direct in-cluster wget from frontend pod"
FP="$(kubectl get pods -n "${PAAS_NS}" -l app.kubernetes.io/name=frontend -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "${FP}" ]]; then
  FP="$(kubectl get pods -n "${PAAS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep frontend | head -1 || true)"
fi
if [[ -n "${FP}" ]]; then
  kubectl exec -n "${PAAS_NS}" "${FP}" -- wget -qO- -T 8 \
    "http://${PROM_SVC}.${MON_NS}.svc:9090/-/ready" 2>/dev/null && echo "OK direct svc" || echo "WARN direct svc failed"
  kubectl exec -n "${PAAS_NS}" "${FP}" -- wget -qO- -T 8 \
    "http://${NODE_IP}:30536/-/ready" 2>/dev/null && echo "OK node NodePort" || echo "WARN node NodePort failed"
fi

echo "==> Kubernetes API service proxy (used by PaaS UI when direct fails)"
API="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo https://kubernetes.default.svc)"
PROXY="${API}/api/v1/namespaces/${MON_NS}/services/http:${PROM_SVC}:9090/proxy/-/ready"
if kubectl get --raw "/api/v1/namespaces/${MON_NS}/services/http:${PROM_SVC}:9090/proxy/-/ready" 2>/dev/null | grep -qi ready; then
  echo "OK k8s API proxy ${PROXY}"
else
  echo "WARN k8s API proxy failed — apply RBAC: kubectl apply -f paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"
  kubectl get --raw "/api/v1/namespaces/${MON_NS}/services/http:${PROM_SVC}:9090/proxy/-/ready" 2>&1 | tail -3 || true
fi
