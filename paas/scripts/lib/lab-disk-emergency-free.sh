#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> EMERGENCY disk free (no image pulls)"
df -h /

echo "==> Scale heavy monitoring (keeps PVC, stops pods)"
kubectl scale statefulset/elasticsearch-master-elasticsearch-master -n monitoring --replicas=0 2>/dev/null || true
kubectl scale deployment/kube-prometheus-stack-grafana -n monitoring --replicas=0 2>/dev/null || true

echo "==> Docker: remove dangling + optional lab pulls (keeps paas/frontend)"
docker image prune -f 2>/dev/null || true
while IFS= read -r img; do
  [[ -z "${img}" ]] && continue
  [[ "${img}" == *paas/frontend* ]] && continue
  docker rmi "${img}" 2>/dev/null || true
done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^(jenkins/|quay.io/argoproj|prom/|postgres:|portainer/|hashicorp/vault|openpolicyagent/|nginx:alpine)' || true)

echo "==> containerd unused images (protected tags first)"
bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" prune || true
sudo journalctl --vacuum-size=100M 2>/dev/null || true

echo "==> Bulk delete Failed pods (all namespaces)"
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${ns}" == kube-* ]] && continue
  kubectl delete pods -n "${ns}" --field-selector=status.phase=Failed \
    --force --grace-period=0 --wait=false 2>/dev/null || true
done

df -h /
kubectl describe node master 2>/dev/null | grep -E 'DiskPressure|Taints' || true
echo "OK: aim for disk < 85% before starting frontend"
