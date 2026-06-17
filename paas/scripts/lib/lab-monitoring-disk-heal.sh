#!/usr/bin/env bash
set -euo pipefail
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"

echo "==> Node disk / pressure"
df -h / /var/lib/rancher 2>/dev/null || df -h /
kubectl describe node master 2>/dev/null | grep -A6 'Conditions:' || kubectl get nodes 2>/dev/null || true
echo "==> k3s storage (PVC data often dominates disk use)"
sudo du -sh /var/lib/rancher/k3s/storage 2>/dev/null || true
kubectl get pvc -n "${MON_NS}" 2>/dev/null || true

echo "==> Evicted / failed pods (monitoring)"
kubectl get pods -n "${MON_NS}" --field-selector status.phase=Failed 2>/dev/null || true

echo "==> Delete evicted pods in ${MON_NS}"
kubectl get pods -n "${MON_NS}" --field-selector status.phase=Failed -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
  | while read -r pod; do
    [[ -z "${pod}" ]] && continue
    kubectl delete pod -n "${MON_NS}" "${pod}" --ignore-not-found --wait=false
  done

echo "==> Prune unused container images (k3s)"
if command -v k3s >/dev/null 2>&1; then
  sudo k3s crictl rmi --prune 2>/dev/null || true
elif command -v crictl >/dev/null 2>&1; then
  sudo crictl rmi --prune 2>/dev/null || true
fi
if command -v docker >/dev/null 2>&1; then
  docker image prune -af 2>/dev/null || true
fi

echo "==> Prometheus stack status"
kubectl get pods -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus-kube|operator|grafana|kube-state' || true
kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus 2>/dev/null || true

EVICTED="$(kubectl get pods -n "${MON_NS}" 2>/dev/null | grep -c Evicted || true)"
if [[ "${EVICTED}" -gt 3 ]]; then
  echo ""
  echo "WARN: ${EVICTED} evicted pods — cluster is out of disk or memory on one or more nodes."
  echo "  On each node: df -h && sudo du -sh /var/lib/rancher/k3s/* | sort -h | tail -5"
  echo "  Free Harbor/Jenkins old images, then re-run: bash paas/scripts/lab.sh prometheus"
fi
