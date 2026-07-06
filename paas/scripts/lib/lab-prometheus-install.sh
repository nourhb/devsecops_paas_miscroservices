#!/usr/bin/env bash
# Lab script to prometheus install on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
RELEASE="${PROMETHEUS_HELM_RELEASE:-kube-prometheus-stack}"
VALUES="${REPO_ROOT}/paas/k8s-manifests/lab/prometheus-helm-lab-values.yaml"
CHART_VERSION="${PROMETHEUS_CHART_VERSION:-}"

log() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

command -v helm >/dev/null 2>&1 || { echo "ERROR: helm required" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl required" >&2; exit 1; }

if kubectl get svc -n "${MON_NS}" kube-prometheus-stack-prometheus >/dev/null 2>&1; then
  log "Prometheus service already exists in ${MON_NS}"
  exit 0
fi

helm_release_status() {
  helm status "${RELEASE}" -n "${MON_NS}" -o json 2>/dev/null \
    | grep -o '"status":"[^"]*"' | head -1 | cut -d'"' -f4 || true
}

clear_stuck_helm_release() {
  local st
  st="$(helm_release_status)"
  [[ -n "${st}" ]] || return 0
  case "${st}" in
    pending-install|pending-upgrade|pending-rollback|failed)
      warn "Helm release ${RELEASE} is ${st} — uninstalling so install can retry"
      helm uninstall "${RELEASE}" -n "${MON_NS}" --wait --timeout 3m 2>/dev/null || \
        helm uninstall "${RELEASE}" -n "${MON_NS}" 2>/dev/null || true
      ;;
  esac
}

log "Install kube-prometheus-stack in ${MON_NS} (release=${RELEASE})"
kubectl create namespace "${MON_NS}" --dry-run=client -o yaml | kubectl apply -f -
clear_stuck_helm_release

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
if ! helm repo update prometheus-community 2>/dev/null; then
  warn "helm repo update failed (offline?) — using cached chart index"
fi

helm_args=(
  upgrade --install "${RELEASE}" prometheus-community/kube-prometheus-stack
  -n "${MON_NS}"
  --timeout 8m
)

if [[ -n "${CHART_VERSION}" ]]; then
  helm_args+=(--version "${CHART_VERSION}")
fi

if [[ -f "${VALUES}" ]]; then
  helm_args+=(-f "${VALUES}")
else
  warn "missing ${VALUES} — using inline NodePort defaults"
  helm_args+=(
    --set prometheus.service.type=NodePort
    --set prometheus.service.nodePort=30536
    --set grafana.enabled=false
    --set alertmanager.enabled=false
    --set kubeStateMetrics.enabled=false
    --set defaultRules.create=false
    --set prometheus.prometheusSpec.retention=2d
  )
fi

if [[ "${PROMETHEUS_LAB_FULL_STACK:-}" == "1" ]]; then
  helm_args+=(
    --set grafana.enabled=true
    --set grafana.service.type=NodePort
    --set grafana.service.nodePort=30083
    --set alertmanager.enabled=true
    --set kubeStateMetrics.enabled=true
    --set defaultRules.create=true
  )
fi

if [[ "${PROMETHEUS_RECOVER_SKIP_GRAFANA:-1}" != "1" && "${PROMETHEUS_LAB_FULL_STACK:-}" != "1" ]]; then
  helm_args+=(
    --set grafana.enabled=true
    --set grafana.service.type=NodePort
    --set grafana.service.nodePort=30083
  )
fi

# Do NOT use --wait here — full stack can sit Pending for 15+ min on a small lab VM.
# lab-prometheus-recover.sh polls prometheus readiness separately.
log "Helm apply (no --wait — expect 1–3 min to render; recover script waits for pods)"
if ! helm "${helm_args[@]}"; then
  warn "helm install returned non-zero — checking partial install"
fi

log "Manifests applied — current monitoring pods:"
kubectl get pods -n "${MON_NS}" -o wide 2>/dev/null || true
kubectl get svc -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|operator|node-exporter' || true

log "Helm release status: $(helm_release_status || echo unknown)"
log "Next: lab-prometheus-recover waits for prometheus-kube-prometheus-stack-prometheus-0"
