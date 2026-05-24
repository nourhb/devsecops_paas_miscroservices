#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-15}"

kubectl_ok() {
  timeout "${KUBECTL_TIMEOUT}" kubectl get --raw=/healthz >/dev/null 2>&1
}

echo "=== Memory / swap (API timeouts often = RAM pressure) ==="
free -h
swapon --show 2>/dev/null || true

echo ""
echo "=== Disk (k3s/etcd needs free space) ==="
df -h / /var/lib/rancher 2>/dev/null || df -h /

echo ""
echo "=== Step 1: Prune unused container images (no kubectl) ==="
sudo k3s crictl rmi --prune 2>/dev/null || true

echo ""
echo "=== Step 2: Restart k3s (clears stuck API / CoreDNS) ==="
echo "This takes 1–3 minutes; Jenkins/PaaS pods will restart."
sudo systemctl restart k3s
sleep 15

echo ""
echo "=== Step 3: Wait for Kubernetes API ==="
for i in $(seq 1 40); do
  if kubectl_ok; then
    echo "API ready (attempt ${i})"
    break
  fi
  echo "  waiting for API... (${i}/40)"
  sleep 5
  if [[ "${i}" -eq 40 ]]; then
    echo "ERROR: API still not responding. Check: sudo journalctl -u k3s -n 80 --no-pager"
    echo "       free -h  — if swap is full, power off optional VMs or add RAM."
    exit 1
  fi
done

echo ""
echo "=== Step 4: Restart cluster DNS ==="
kubectl delete pod -n kube-system -l k8s-app=kube-dns --force --grace-period=0 2>/dev/null || true
kubectl delete pod -n kube-system -l app.kubernetes.io/name=coredns --force --grace-period=0 2>/dev/null || true
kubectl rollout restart deployment/coredns -n kube-system 2>/dev/null || true
kubectl wait --for=condition=ready pod -l k8s-app=kube-dns -n kube-system --timeout=120s 2>/dev/null || \
  kubectl get pods -n kube-system | grep -i dns || true

echo ""
echo "=== Step 5: Light memory cleanup (optional stacks) ==="
for ns in monitoring tekton-pipelines kubewarden kyverno gatekeeper-system; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    kubectl scale deployment,statefulset -n "$ns" --all --replicas=0 2>/dev/null || true
  fi
done
kubectl delete pod -A --field-selector=status.phase=Failed 2>/dev/null || true
kubectl delete pod -A --field-selector=status.phase=Succeeded 2>/dev/null || true

echo ""
echo "=== Step 6: Ensure Jenkins is running ==="
if ! kubectl get deployment jenkins -n cicd >/dev/null 2>&1; then
  kubectl apply -f "${REPO_ROOT}/paas/k8s-manifests/lab/jenkins-cicd-emptydir.yaml" 2>/dev/null || true
fi
kubectl rollout status deployment/jenkins -n cicd --timeout=300s 2>/dev/null || \
  kubectl get pods -n cicd -l app=jenkins

echo ""
echo "=== Step 7: Jenkins DNS (public resolvers) ==="
bash "${REPO_ROOT}/paas/scripts/fix-jenkins-dns-lab.sh" || true

echo ""
echo "=== Step 8: PaaS Postgres + login (after k3s restart) ==="
bash "${REPO_ROOT}/paas/scripts/recover-paas-after-k3s-restart.sh" || echo "WARN: PaaS recovery failed — run bash paas/scripts/bootstrap-paas-lab.sh"

echo ""
free -h
echo ""
echo "OK — API recovered. Re-run paas-deploy build, then check PaaS login at http://192.168.56.129:30100"
