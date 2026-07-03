#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
RELEASE="${PROMETHEUS_HELM_RELEASE:-kube-prometheus-stack}"
VALUES="${REPO_ROOT}/paas/k8s-manifests/lab/prometheus-helm-lab-values.yaml"

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl required" >&2; exit 1; }

if kubectl get svc -n "${MON_NS}" kube-prometheus-stack-prometheus >/dev/null 2>&1; then
  log "Prometheus service already exists in ${MON_NS}"
  exit 0
fi

log "Install kube-prometheus-stack in ${MON_NS} (release=${RELEASE})"
kubectl create namespace "${MON_NS}" --dry-run=client -o yaml | kubectl apply -f -
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

helm_args=(
  upgrade --install "${RELEASE}" prometheus-community/kube-prometheus-stack
  -n "${MON_NS}"
  --timeout 15m
  --wait
)

if [[ -f "${VALUES}" ]]; then
  helm_args+=(-f "${VALUES}")
else
  warn "missing ${VALUES} — using inline NodePort defaults"
  helm_args+=(
    --set prometheus.service.type=NodePort
    --set prometheus.service.nodePort=30536
    --set grafana.service.type=NodePort
    --set grafana.service.nodePort=30083
    --set prometheus.prometheusSpec.retention=2d
  )
fi

if [[ "${PROMETHEUS_RECOVER_SKIP_GRAFANA:-}" == "1" ]]; then
  helm_args+=(--set grafana.enabled=false)
fi

if ! helm "${helm_args[@]}"; then
  warn "helm install returned non-zero — checking partial install"
fi

log "Waiting for prometheus operator"
kubectl rollout status deployment/"${RELEASE}"-operator -n "${MON_NS}" --timeout=300s 2>/dev/null || \
  kubectl rollout status deployment/kube-prometheus-stack-operator -n "${MON_NS}" --timeout=300s 2>/dev/null || true

log "Prometheus workloads"
kubectl get pods,svc -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|operator|grafana|alertmanager|kube-state' || true
