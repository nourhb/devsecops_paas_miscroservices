#!/usr/bin/env bash
# Check whether old Jenkins home (cicd/jenkins-pvc) can be restored; optionally switch to PVC deploy.
# Run on lab master: bash paas/scripts/jenkins-restore-data-lab.sh
set -euo pipefail

NS=cicd
PVC=jenkins-pvc
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== 1. Current Jenkins storage (cicd) ==="
kubectl get deploy,pvc,pv,pods -n "$NS" -l app=jenkins 2>/dev/null || kubectl get deploy,pvc,pods -n "$NS" 2>/dev/null | grep -i jenkins || true

echo ""
echo "=== 2. Released PVs (orphan disk after PVC delete) ==="
kubectl get pv -o custom-columns=NAME:.metadata.name,STATUS:.status.phase,CLAIM:.spec.claimRef.name,STORAGE:.spec.storageClassName,PATH:.spec.local.path 2>/dev/null \
  | grep -E 'NAME|Released|jenkins' || kubectl get pv | grep -i jenkins || echo "(no jenkins-named PV in API)"

echo ""
echo "=== 3. local-path dirs on this node (master) ==="
if [ -d /var/lib/rancher/k3s/storage ]; then
  sudo find /var/lib/rancher/k3s/storage -maxdepth 2 -type d 2>/dev/null | head -20 || true
  echo "Tip: large dirs may be old Jenkins home if PVC was deleted while PV remained Released."
else
  echo "/var/lib/rancher/k3s/storage not found on this host."
fi

echo ""
echo "=== 4. Interpretation ==="
if kubectl get pvc -n "$NS" "$PVC" >/dev/null 2>&1; then
  phase=$(kubectl get pvc -n "$NS" "$PVC" -o jsonpath='{.status.phase}')
  echo "PVC $PVC exists (phase=$phase). Redeploy with PVC manifest to reuse data:"
  echo "  kubectl apply -f ${REPO_ROOT}/k8s-manifests/lab/jenkins-cicd-pvc.yaml"
elif kubectl get pv 2>/dev/null | grep -q Released; then
  echo "PVC missing but Released PV(s) exist — data may still be on disk."
  echo "Advanced: recreate PVC with volumeName=<released-pv> (see k8s docs) or copy dir into new PVC."
else
  echo "No PVC and no obvious Released PV — old Jenkins jobs/config are likely gone."
  echo "Recreate job: python3 ${REPO_ROOT}/scripts/create_jenkins_paas_deploy_job.py --minimal"
  echo "Then full Jenkinsfile or PaaS sync."
fi

echo ""
echo "=== 5. Optional: switch from emptyDir to PVC (new empty volume if PVC never existed) ==="
echo "  kubectl delete deployment jenkins -n $NS --wait=true"
echo "  kubectl apply -f ${REPO_ROOT}/k8s-manifests/lab/jenkins-cicd-pvc.yaml"
echo "  kubectl get pods -n $NS -l app=jenkins -w"
echo ""
echo "WARNING: Do not run recover-k3s-memory-lab.sh if you need to keep jenkins-pvc."
