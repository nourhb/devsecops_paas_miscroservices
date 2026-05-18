#!/usr/bin/env bash
# Copy Harbor pull secret + scaffold gitops chart into nourhb/gitops (lab).
# Usage: bash paas/scripts/bootstrap-simple-app-gitops.sh [jenkins-build-number]
set -euo pipefail

BUILD_NUM="${1:-99}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART_SRC="${REPO_ROOT}/paas/gitops/apps/simple-app"
NS="simple-app"
HARBOR_NS="${HARBOR_NS:-paas}"

echo "=== 1. Namespace ${NS} ==="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "=== 2. Copy harbor-regcred from ${HARBOR_NS} → ${NS} ==="
if kubectl get secret harbor-regcred -n "$HARBOR_NS" >/dev/null 2>&1; then
  kubectl get secret harbor-regcred -n "$HARBOR_NS" -o yaml \
    | sed "s/namespace: ${HARBOR_NS}/namespace: ${NS}/" \
    | kubectl apply -f -
else
  echo "WARN: harbor-regcred not in ${HARBOR_NS}; create it or image pull will fail."
fi

echo "=== 3. GitOps chart files to push (manual) ==="
echo "Copy everything under:"
echo "  ${CHART_SRC}/"
echo "into your GitHub repo:"
echo "  https://github.com/nourhb/gitops/tree/main/apps/simple-app"
echo ""
echo "Required files:"
find "$CHART_SRC" -type f | sed "s|^|  |"
echo ""
echo "Set image tag in values.yaml to your Jenkins build, e.g.:"
echo "  tag: \"${BUILD_NUM}\""
echo ""
echo "Then commit + push gitops, and run:"
echo "  argocd app sync paas-simple-app --force"
echo "  kubectl get pods,svc,ingress -n ${NS}"
echo "  curl -sS -o /dev/null -w '%{http_code}\\n' http://simple-app.192.168.56.129.nip.io:30659/"
