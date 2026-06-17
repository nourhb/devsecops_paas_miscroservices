#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
QUICK="${PAAS_DISK_QUICK:-0}"

echo "==> Node disk / pressure"
df -h / /var/lib/rancher 2>/dev/null || df -h /
kubectl describe node master 2>/dev/null | grep -A6 'Conditions:' || kubectl get nodes 2>/dev/null || true
echo "==> k3s storage (PVC data often dominates disk use)"
sudo du -sh /var/lib/rancher/k3s/storage 2>/dev/null || true
kubectl get pvc -A --sort-by=.spec.resources.requests.storage 2>/dev/null | tail -8 || true

echo "==> Stale pods (all namespaces — evicted/Failed/ImagePullBackOff)"
bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh"

if [[ "${QUICK}" == "1" || "${1:-}" == "quick" ]]; then
  echo "==> Quick mode — no image pulls, no prometheus recover"
  sudo journalctl --vacuum-size=100M 2>/dev/null || true
  DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 85 ]]; then
    echo "WARN: disk at ${DISK_PCT}% — run: bash paas/scripts/lab.sh disk-emergency"
  fi
  exit 0
fi

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 88 && "${PAAS_DISK_FORCE:-}" != "1" ]]; then
  echo "ERROR: disk at ${DISK_PCT}% — full monitoring-disk is unsafe (can pull images and worsen pressure)." >&2
  echo "  Use: bash paas/scripts/lab.sh disk-emergency" >&2
  echo "  Or:  PAAS_DISK_FORCE=1 bash paas/scripts/lab.sh monitoring-disk" >&2
  exit 1
fi

echo "==> Safe image prune (never docker image prune -af)"
bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" prune

echo "==> Prometheus stack status"
kubectl get pods -n "${MON_NS}" 2>/dev/null | grep -iE 'prometheus-kube|operator|grafana|kube-state' || true
PROM_EP="$(kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
if [[ -z "${PROM_EP}" ]]; then
  echo "WARN: no prometheus endpoints — auto-recover"
  PROMETHEUS_RECOVER_SKIP_GRAFANA=1 bash "${SCRIPT_DIR}/lab-prometheus-recover.sh" || true
else
  kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus 2>/dev/null || true
fi

DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 85 ]]; then
  echo ""
  echo "WARN: disk still at ${DISK_PCT}% — consider:"
  echo "  PROMETHEUS_RECOVER_SKIP_GRAFANA=1 kubectl scale deployment/kube-prometheus-stack-grafana -n monitoring --replicas=0"
  echo "  Review large PVCs: kubectl get pvc -A --sort-by=.spec.resources.requests.storage"
fi
