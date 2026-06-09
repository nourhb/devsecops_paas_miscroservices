#!/usr/bin/env bash
# Deploy a Harbor tag to sanhome without Git push (kubectl + optional Argo sync).
set -euo pipefail
TAG="${1:?usage: deploy-sanhome-image-lab.sh <buildNumber>}"
NS="${NS:-sanhome}"
APP="${ARGOCD_APP:-paas-sanhome}"
REPO="${HARBOR_REGISTRY:-192.168.56.129:30002}/paas/sanhome"
IMAGE="${REPO}:${TAG}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "==> Set all deployments in ${NS} to ${IMAGE}"
for d in $(kubectl get deploy -n "${NS}" -o name 2>/dev/null); do
  kubectl set image -n "${NS}" "${d}" "*=${IMAGE}" --record=false
done
kubectl rollout status "deploy/paas-sanhome-green" -n "${NS}" --timeout=300s 2>/dev/null \
  || kubectl rollout status "deploy/paas-sanhome-blue" -n "${NS}" --timeout=300s 2>/dev/null \
  || kubectl get pods -n "${NS}"

if command -v kubectl >/dev/null 2>&1; then
  # shellcheck source=lib/argo-sync-lab.sh
  source "${SCRIPT_DIR}/lib/argo-sync-lab.sh" 2>/dev/null || true
  argo_sync_app_lab "${APP}" 2>/dev/null || true
fi

echo "OK: cluster should run ${IMAGE}"
kubectl get deploy -n "${NS}" -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
