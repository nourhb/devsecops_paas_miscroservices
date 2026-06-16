#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "==> Kyverno: ensure monitoring namespace is excluded (Prometheus/Grafana blocked otherwise)"
for pol in require-non-root require-signed-images; do
  manifest="${REPO_ROOT}/paas/k8s-manifests/kyverno/${pol}.yaml"
  if [[ -f "${manifest}" ]]; then
    kubectl apply -f "${manifest}" >/dev/null 2>&1 || true
  fi
done
if kubectl get clusterpolicy require-non-root >/dev/null 2>&1; then
  if ! kubectl get clusterpolicy require-non-root -o yaml 2>/dev/null | grep -q 'monitoring'; then
    echo "WARN: require-non-root still missing monitoring exclude — re-applying manifest"
    kubectl apply -f "${REPO_ROOT}/paas/k8s-manifests/kyverno/require-non-root.yaml"
  fi
fi
bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" 2>/dev/null || true

echo "==> Prometheus / operator pods in ${MON_NS}"
kubectl get pods -n "${MON_NS}" -o wide 2>/dev/null | grep -iE 'prometheus|operator|alertmanager|grafana|kube-state' || true
kubectl get sts,deploy -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|operator|alertmanager|grafana|kube-state' || true

echo "==> Service endpoints (prometheus*)"
kubectl get endpoints -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|grafana|alertmanager|operator' || echo "WARN: no prometheus/grafana endpoints"

echo "==> Prometheus operator CR"
kubectl get prometheus -n "${MON_NS}" 2>/dev/null || true

echo "==> Recent Kyverno blocks in ${MON_NS}"
kubectl get events -n "${MON_NS}" --field-selector reason=PolicyViolation --sort-by='.lastTimestamp' 2>/dev/null | tail -8 || true

restart_prometheus_workloads() {
  local line kind name
  while IFS= read -r line; do
    kind="${line%%/*}"
    name="${line#*/}"
    [[ -z "${name}" ]] && continue
    echo "==> rollout restart ${kind}/${name}"
    kubectl rollout restart -n "${MON_NS}" "${kind}/${name}" 2>/dev/null || true
  done < <(
    kubectl get sts,deploy -n "${MON_NS}" -o name 2>/dev/null | grep -iE 'prometheus|kube-prometheus-stack-operator|alertmanager|grafana|kube-state-metrics' || true
  )
}

restart_prometheus_workloads

echo "==> Delete stale prometheus/operator pods (if any) so they recreate without Kyverno block"
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=prometheus --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=prometheus-operator --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=alertmanager --ignore-not-found --wait=false 2>/dev/null || true
kubectl delete pods -n "${MON_NS}" -l app.kubernetes.io/name=grafana --ignore-not-found --wait=false 2>/dev/null || true

echo "==> Wait up to 6 min for prometheus/grafana/operator endpoints"
for i in $(seq 1 36); do
  for svc in kube-prometheus-stack-prometheus prometheus-operated prometheus-service kube-prometheus-stack-operator; do
    ip="$(kubectl get endpoints -n "${MON_NS}" "${svc}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      echo "OK ${svc} endpoint ${ip}"
      kubectl get pods -n "${MON_NS}" -l app.kubernetes.io/name=prometheus 2>/dev/null || true
      if curl -fsS --connect-timeout 5 "http://${NODE_IP}:30536/-/ready" >/dev/null 2>&1; then
        echo "OK NodePort :30536 ready"
      elif curl -fsS --connect-timeout 5 "http://${NODE_IP}:30083/-/ready" >/dev/null 2>&1; then
        echo "OK NodePort :30083 ready"
      fi
      exit 0
    fi
  done
  if (( i % 6 == 0 )); then
    echo "... still waiting (${i}0s) — pods:"
    kubectl get pods -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus|operator|alertmanager|grafana' || true
  fi
  sleep 10
done

echo "ERROR: Prometheus still has no endpoints in ${MON_NS}" >&2
echo "  kubectl get pods -n ${MON_NS} -o wide" >&2
echo "  kubectl describe sts -n ${MON_NS} prometheus-kube-prometheus-stack-prometheus" >&2
echo "  kubectl get events -n ${MON_NS} --sort-by='.lastTimestamp' | tail -20" >&2
exit 1
