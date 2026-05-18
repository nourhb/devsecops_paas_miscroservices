#!/usr/bin/env bash
# End-to-end lab checks after a PaaS deploy. Usage:
#   bash paas/scripts/verify-deployment-lab.sh simple-app [build-number]
set -euo pipefail

PROJECT="${1:-}"
BUILD="${2:-}"
if [[ -z "$PROJECT" ]]; then
  echo "Usage: $0 <project-name> [jenkins-build-number]"
  exit 1
fi

NS="$PROJECT"
APP="paas-${PROJECT}"
HARBOR="192.168.56.129:30002"
NODE_IP="${NODE_IP:-192.168.56.129}"
INGRESS_PORT="${INGRESS_PORT:-30659}"

echo "=== 1. Jenkins job (last build) ==="
if command -v jenkins-cli >/dev/null 2>&1; then
  jenkins-cli list-builds paas-deploy 2>/dev/null | tail -3 || true
else
  echo "Tip: open http://${NODE_IP}:30090/job/paas-deploy/ and confirm last build SUCCESS"
fi

echo ""
echo "=== 2. Harbor image ==="
TAG="${BUILD:-latest}"
IMG="${HARBOR}/paas/${PROJECT}:${TAG}"
echo "Expected: ${IMG}"
if command -v curl >/dev/null 2>&1; then
  curl -sS -o /dev/null -w "Harbor API HTTP %{http_code}\n" "http://${HARBOR}/api/v2.0/projects/paas/repositories/${PROJECT}/artifacts" || true
fi

echo ""
echo "=== 3. Argo CD application ==="
if command -v argocd >/dev/null 2>&1; then
  argocd app get "$APP" -o wide 2>/dev/null || echo "WARN: argocd app $APP not found or CLI not logged in"
else
  echo "argocd CLI not installed — check https://${NODE_IP}:30374/applications/${APP}"
fi

echo ""
echo "=== 4. Kubernetes namespace ${NS} ==="
kubectl get ns "$NS" 2>/dev/null || echo "WARN: namespace $NS missing"
kubectl get deploy,po,svc,ingress -n "$NS" 2>/dev/null || true

echo ""
echo "=== 5. HTTP reachability (nip.io + Traefik NodePort) ==="
URL="http://${PROJECT}.${NODE_IP}.nip.io:${INGRESS_PORT}"
echo "Trying: $URL"
if command -v curl >/dev/null 2>&1; then
  curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 8 "$URL" || echo "FAIL: no response (enable ingress in gitops values)"
else
  echo "Install curl to probe URL"
fi

echo ""
echo "=== Done ==="
echo "Jenkins log markers: PAAS_STEP_OK step=1..12 and PAAS_BUILD_COMPLETE"
echo "PaaS deploy log markers: PAAS_DEPLOY_VERIFY step=gitops|argocd|url status=OK"
