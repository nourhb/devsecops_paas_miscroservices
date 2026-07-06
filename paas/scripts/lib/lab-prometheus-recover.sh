#!/usr/bin/env bash
# Lab script to prometheus recover on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "==> lab-prometheus-recover (install if missing; never tear down a healthy stack)"

require_non_root="${REPO_ROOT}/paas/k8s-manifests/kyverno/require-non-root.yaml"
require_signed="${REPO_ROOT}/paas/k8s-manifests/kyverno/require-signed-images.yaml"

kyverno_installed() {
  kubectl api-resources --api-group=kyverno.io 2>/dev/null | grep -q ClusterPolicy
}

prometheus_pod_ready() {
  kubectl get pod -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True
}

prometheus_endpoint_ip() {
  kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus \
    -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true
}

prometheus_http_ready() {
  local ip="${1:-}"
  [[ -n "${ip}" ]] || return 1
  curl -fsS --connect-timeout 5 "http://${ip}:9090/-/ready" 2>/dev/null | grep -qi ready
}

prometheus_healthy() {
  local ip
  ip="$(prometheus_endpoint_ip)"
  prometheus_pod_ready && [[ -n "${ip}" ]] && prometheus_http_ready "${ip}"
}

apply_kyverno_policies() {
  if ! kyverno_installed; then
    echo "==> Skip Kyverno policies (kyverno.io CRDs not installed)"
    return 0
  fi
  if [[ ! -f "${require_non_root}" ]] || ! grep -q 'monitoring' "${require_non_root}"; then
    echo "WARN: repo missing Kyverno monitoring exclude — run: git pull" >&2
    return 0
  fi
  if ! kubectl get endpoints -n kyverno kyverno-svc -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    echo "==> Kyverno admission webhook down — restart before policy replace"
    kubectl rollout restart deployment/kyverno-admission-controller -n kyverno 2>/dev/null || true
    kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=180s 2>/dev/null || true
  fi
  echo "==> Apply Kyverno policies (monitoring namespace must be excluded)"
  kubectl replace -f "${require_non_root}" --force 2>/dev/null || kubectl apply -f "${require_non_root}" || {
    echo "WARN: could not apply require-non-root — continuing without Kyverno" >&2
    return 0
  }
  if [[ -f "${require_signed}" ]]; then
    COSIGN_LAB_ENFORCE_SIGNED="${COSIGN_LAB_ENFORCE_SIGNED:-false}" \
      bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" || {
      echo "WARN: apply-kyverno-cosign-lab.sh failed — applying base require-signed-images" >&2
      kubectl replace -f "${require_signed}" --force 2>/dev/null || true
    }
  fi
}

verify_kyverno_monitoring_exclude() {
  if ! kyverno_installed; then
    return 0
  fi
  local yaml
  yaml="$(kubectl get clusterpolicy require-non-root -o yaml 2>/dev/null || true)"
  if ! grep -qE '^[[:space:]]*-[[:space:]]*monitoring[[:space:]]*$' <<<"${yaml}"; then
    echo "WARN: live require-non-root may still block monitoring namespace" >&2
    return 0
  fi
  echo "OK live require-non-root excludes monitoring"
}

prometheus_stack_present() {
  kubectl get svc -n "${MON_NS}" kube-prometheus-stack-prometheus >/dev/null 2>&1 \
    || kubectl get deploy -n "${MON_NS}" kube-prometheus-stack-operator >/dev/null 2>&1 \
    || kubectl get prometheus -n "${MON_NS}" kube-prometheus-stack-prometheus >/dev/null 2>&1
}

ensure_prometheus_installed() {
  if prometheus_stack_present; then
    return 0
  fi
  echo "==> No Prometheus stack in ${MON_NS} — helm install (async, no --wait)"
  bash "${SCRIPT_DIR}/lab-prometheus-install.sh"
  echo "==> Waiting for operator deployment (up to 5 min)"
  for i in $(seq 1 30); do
    if kubectl get deployment kube-prometheus-stack-operator -n "${MON_NS}" >/dev/null 2>&1; then
      kubectl rollout status deployment/kube-prometheus-stack-operator -n "${MON_NS}" --timeout=60s 2>/dev/null && break
    fi
    echo "... operator not ready yet (${i}/30)"
    kubectl get pods -n "${MON_NS}" 2>/dev/null | head -12 || true
    sleep 10
  done
}

scale_if_zero() {
  local kind="$1"
  local name="$2"
  local target="${3:-1}"
  if ! kubectl get "${kind}" "${name}" -n "${MON_NS}" >/dev/null 2>&1; then
    return 0
  fi
  local cur
  cur="$(kubectl get "${kind}" "${name}" -n "${MON_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  if [[ -z "${cur}" ]] || [[ "${cur}" == "0" ]]; then
    echo "==> scale ${kind}/${name} ${cur:-0} -> ${target}"
    kubectl scale "${kind}" "${name}" -n "${MON_NS}" --replicas="${target}"
  fi
}

scale_up_monitoring_stack() {
  echo "==> Scale up monitoring stack (only zero-replica workloads)"
  scale_if_zero deployment kube-prometheus-stack-operator 1
  scale_if_zero statefulset prometheus-kube-prometheus-stack-prometheus 1
  if [[ "${PROMETHEUS_RECOVER_SKIP_GRAFANA:-1}" != "1" ]]; then
    scale_if_zero deployment kube-prometheus-stack-grafana "${PROMETHEUS_RECOVER_GRAFANA_REPLICAS:-1}"
  else
    echo "==> Skip grafana scale (PROMETHEUS_RECOVER_SKIP_GRAFANA=1)"
  fi
  if [[ "${PROMETHEUS_LAB_FULL_STACK:-}" == "1" ]]; then
    scale_if_zero statefulset alertmanager-kube-prometheus-stack-alertmanager 1
    scale_if_zero deployment kube-prometheus-stack-kube-state-metrics 1
  fi
}

wait_for_prometheus() {
  echo "==> Wait up to 8 min for prometheus pod Ready + endpoint"
  for i in $(seq 1 48); do
    local prom_phase prom_ip pod_ip
    prom_phase="$(kubectl get pod -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
    prom_ip="$(prometheus_endpoint_ip)"
    pod_ip="$(kubectl get pod -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
    if [[ "${prom_phase}" == "True" ]]; then
      if [[ -n "${prom_ip}" ]] || prometheus_http_ready "${pod_ip}"; then
        echo "OK prometheus-kube-prometheus-stack-prometheus-0 Ready; endpoint=${prom_ip:-$pod_ip}"
        if curl -fsS --connect-timeout 5 "http://${NODE_IP}:30536/-/ready" 2>/dev/null | grep -qi ready; then
          echo "OK NodePort :30536 ready"
        fi
        return 0
      fi
    fi
    if (( i % 6 == 0 )); then
      echo "... still waiting (${i}0s) ready=${prom_phase:-False} endpoint=${prom_ip:-none} pod=${pod_ip:-none}"
      kubectl get pods -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 2>/dev/null || true
      local pull_reason
      pull_reason="$(kubectl get pod -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 \
        -o jsonpath='{.status.initContainerStatuses[0].state.waiting.reason}{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
      if [[ "${pull_reason}" == *ImagePull* || "${pull_reason}" == *BackOff* ]]; then
        echo "WARN: image pull failing — fix VM DNS/network before re-running recover:" >&2
        echo "  kubectl describe pod -n ${MON_NS} prometheus-kube-prometheus-stack-prometheus-0 | tail -15" >&2
        echo "  getent hosts quay.io || ping -c1 8.8.8.8" >&2
      fi
    fi
    sleep 10
  done
  return 1
}

apply_kyverno_policies
verify_kyverno_monitoring_exclude

if prometheus_healthy && [[ "${PROMETHEUS_FORCE_RECOVER:-}" != "1" ]]; then
  echo "OK Prometheus already healthy — skip restarts/deletes (PROMETHEUS_FORCE_RECOVER=1 to force)"
  exit 0
fi

ensure_prometheus_installed

echo "==> Current monitoring workloads"
kubectl get pods -n "${MON_NS}" -o wide 2>/dev/null | grep -iE 'prometheus|operator|node-exporter' || true
kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus 2>/dev/null || true

scale_up_monitoring_stack

if wait_for_prometheus; then
  exit 0
fi

echo "ERROR: Prometheus still not ready in ${MON_NS}" >&2
echo "  Do NOT helm uninstall if pods were ever Ready — fix DNS then wait for ImagePullBackOff to retry." >&2
echo "  kubectl get pods -n ${MON_NS} -o wide" >&2
echo "  kubectl describe pod -n ${MON_NS} prometheus-kube-prometheus-stack-prometheus-0 | tail -20" >&2
exit 1
