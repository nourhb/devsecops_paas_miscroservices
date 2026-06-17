#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "==> lab-prometheus-recover (Kyverno monitoring exclude + operator-first)"

require_non_root="${REPO_ROOT}/paas/k8s-manifests/kyverno/require-non-root.yaml"
require_signed="${REPO_ROOT}/paas/k8s-manifests/kyverno/require-signed-images.yaml"

if [[ ! -f "${require_non_root}" ]] || ! grep -q 'monitoring' "${require_non_root}"; then
  echo "ERROR: repo missing Kyverno monitoring exclude — run: cd ${REPO_ROOT} && git pull" >&2
  exit 1
fi

apply_kyverno_policies() {
  if ! kubectl get endpoints -n kyverno kyverno-svc -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .; then
    echo "==> Kyverno admission webhook down — restart before policy replace"
    kubectl rollout restart deployment/kyverno-admission-controller -n kyverno 2>/dev/null || true
    kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=180s 2>/dev/null || true
  fi
  echo "==> Apply Kyverno policies (monitoring namespace must be excluded)"
  kubectl replace -f "${require_non_root}" --force || kubectl apply -f "${require_non_root}"
  if [[ -f "${require_signed}" ]]; then
    COSIGN_LAB_ENFORCE_SIGNED="${COSIGN_LAB_ENFORCE_SIGNED:-false}" \
      bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" || {
      echo "WARN: apply-kyverno-cosign-lab.sh failed — applying base require-signed-images" >&2
      kubectl replace -f "${require_signed}" --force
    }
  fi
}

verify_kyverno_monitoring_exclude() {
  local yaml
  yaml="$(kubectl get clusterpolicy require-non-root -o yaml 2>/dev/null || true)"
  if ! grep -qE '^[[:space:]]*-[[:space:]]*monitoring[[:space:]]*$' <<<"${yaml}"; then
    echo "ERROR: live require-non-root still blocks monitoring namespace" >&2
    echo "  kubectl get clusterpolicy require-non-root -o yaml | grep -A20 exclude" >&2
    exit 1
  fi
  echo "OK live require-non-root excludes monitoring"
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
  echo "==> Scale up monitoring stack (Kyverno may have scaled everything to 0/0)"
  scale_if_zero deployment kube-prometheus-stack-operator 1
  if kubectl get deployment kube-prometheus-stack-operator -n "${MON_NS}" >/dev/null 2>&1; then
    kubectl rollout status deployment/kube-prometheus-stack-operator -n "${MON_NS}" --timeout=300s 2>/dev/null || {
      echo "WARN: operator deployment not ready yet"
      kubectl get pods -n "${MON_NS}" -l app.kubernetes.io/name=prometheus-operator 2>/dev/null || true
    }
  fi
  scale_if_zero statefulset prometheus-kube-prometheus-stack-prometheus 1
  scale_if_zero statefulset alertmanager-kube-prometheus-stack-alertmanager 1
  scale_if_zero deployment kube-prometheus-stack-grafana 1
  scale_if_zero deployment kube-prometheus-stack-kube-state-metrics 1
  if kubectl get prometheus kube-prometheus-stack-prometheus -n "${MON_NS}" >/dev/null 2>&1; then
    kubectl annotate prometheus kube-prometheus-stack-prometheus -n "${MON_NS}" \
      paas-lab-recover="$(date +%s)" --overwrite >/dev/null 2>&1 || true
  fi
}

apply_kyverno_policies
verify_kyverno_monitoring_exclude

echo "==> Current monitoring workloads"
kubectl get pods -n "${MON_NS}" -o wide 2>/dev/null | grep -iE 'prometheus|operator|alertmanager|grafana|kube-state' || true
kubectl get sts,deploy -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|operator|alertmanager|grafana|kube-state' || true
kubectl get endpoints -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|grafana|alertmanager|operator' || true

echo "==> Recent Kyverno blocks in ${MON_NS}"
kubectl get events -n "${MON_NS}" --field-selector reason=PolicyViolation --sort-by='.lastTimestamp' 2>/dev/null | tail -6 || true

scale_up_monitoring_stack

echo "==> Operator rollout (after scale-up)"
kubectl rollout restart deployment/kube-prometheus-stack-operator -n "${MON_NS}" 2>/dev/null || true
kubectl rollout status deployment/kube-prometheus-stack-operator -n "${MON_NS}" --timeout=300s 2>/dev/null || {
  echo "WARN: operator not ready — describe:"
  kubectl describe deployment/kube-prometheus-stack-operator -n "${MON_NS}" 2>/dev/null | tail -25 || true
}

restart_prometheus_workloads() {
  local line kind name
  while IFS= read -r line; do
    kind="${line%%/*}"
    name="${line#*/}"
    [[ -z "${name}" ]] && continue
    [[ "${name}" == "kube-prometheus-stack-operator" ]] && continue
    echo "==> rollout restart ${kind}/${name}"
    kubectl rollout restart -n "${MON_NS}" "${kind}/${name}" 2>/dev/null || true
  done < <(
    kubectl get sts,deploy -n "${MON_NS}" -o name 2>/dev/null | grep -iE 'prometheus|alertmanager|grafana|kube-state-metrics' || true
  )
}

restart_prometheus_workloads

echo "==> Delete blocked/stale pods so they recreate under updated Kyverno policy"
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=prometheus-operator --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=prometheus --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=alertmanager --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=grafana --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=kube-state-metrics --ignore-not-found --wait=false 2>/dev/null || true

echo "==> Wait up to 8 min for prometheus pod 2/2 + service endpoint"
for i in $(seq 1 48); do
  prom_phase="$(kubectl get pod -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  prom_ip="$(kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
  pod_ip="$(kubectl get pod -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 -o jsonpath='{.status.podIP}' 2>/dev/null || true)"
  if [[ "${prom_phase}" == "True" ]]; then
    if [[ -n "${prom_ip}" ]] || { [[ -n "${pod_ip}" ]] && curl -fsS --connect-timeout 5 "http://${pod_ip}:9090/-/ready" 2>/dev/null | grep -qi ready; }; then
      echo "OK prometheus-kube-prometheus-stack-prometheus-0 Ready; endpoint=${prom_ip:-$pod_ip}"
      if curl -fsS --connect-timeout 5 "http://${NODE_IP}:30536/-/ready" 2>/dev/null | grep -qi ready; then
        echo "OK NodePort :30536 ready"
      fi
      exit 0
    fi
  fi
  if (( i % 6 == 0 )); then
    echo "... still waiting (${i}0s) ready=${prom_phase:-False} endpoint=${prom_ip:-none} pod=${pod_ip:-none}"
    kubectl get pods -n "${MON_NS}" prometheus-kube-prometheus-stack-prometheus-0 2>/dev/null || true
    kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus 2>/dev/null || true
  fi
  sleep 10
done

echo "ERROR: Prometheus still has no endpoints in ${MON_NS}" >&2
echo "  kubectl get pods -n ${MON_NS} -o wide" >&2
echo "  kubectl describe deployment/kube-prometheus-stack-operator -n ${MON_NS}" >&2
echo "  kubectl describe sts prometheus-kube-prometheus-stack-prometheus -n ${MON_NS}" >&2
exit 1
