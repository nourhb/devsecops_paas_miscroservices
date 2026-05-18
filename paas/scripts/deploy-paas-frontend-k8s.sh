#!/usr/bin/env bash
# Build PaaS frontend image, push to Harbor, restart in-cluster deployment.
# Run on lab master: bash paas/scripts/deploy-paas-frontend-k8s.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

HARBOR="${HARBOR_REGISTRY:-192.168.56.129:30002}"
IMAGE="${HARBOR}/paas/paas-frontend:latest"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"

echo "==> Building ${IMAGE}"
docker build -f docker/frontend.Dockerfile -t "$IMAGE" .

echo "==> Pushing to Harbor"
echo "$HARBOR_PASS" | docker login "$HARBOR" -u "$HARBOR_USER" --password-stdin
docker push "$IMAGE"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
echo "==> Restarting deployment/frontend in namespace paas"
kubectl rollout restart deployment/frontend -n paas
kubectl rollout status deployment/frontend -n paas --timeout=300s

curl -sf "http://127.0.0.1:30100/api/health" | head -c 200 || true
echo ""
echo "OK: http://192.168.56.129:30100"
