#!/usr/bin/env bash
set -euo pipefail

echo "==> Memory before"
free -h

echo "==> Scale down heavy optional stacks (adjust if you need them for demo)"
for ns in monitoring tekton-pipelines kubewarden kyverno gatekeeper-system; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    kubectl scale deployment,statefulset -n "$ns" --all --replicas=0 2>/dev/null || true
  fi
done

echo "==> Restart Jenkins in cicd (keeps jenkins-pvc if present — does NOT delete PVC)"
kubectl delete deployment jenkins -n cicd --ignore-not-found --wait=false
kubectl delete pod -n cicd -l app=jenkins --force --grace-period=0 2>/dev/null || true

echo "==> Prune unused images on master"
sudo k3s crictl rmi --prune 2>/dev/null || true

echo "==> Memory after (wait ~30s for pods to terminate)"
sleep 30
free -h
echo ""
echo "Next: kubectl apply -f paas/k8s-manifests/lab/jenkins-cicd-emptydir.yaml"
echo "      kubectl get pods -n cicd -l app=jenkins -w"
