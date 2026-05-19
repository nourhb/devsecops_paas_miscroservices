#!/usr/bin/env bash
# Fix PaaS Argo CD HTTP 403 on new projects (permission denied on GET /api/v1/applications/paas-*).
# Refreshes ARGOCD_AUTH_TOKEN on deployment/frontend using cluster admin credentials.
#
# Run on lab master:
#   bash paas/scripts/fix-argocd-token-lab.sh
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
ARGOCD_BASE_URL="${ARGOCD_BASE_URL:-https://${NODE_IP}:30374}"
PAAS_NS="${PAAS_NS:-paas}"
ARGO_NS="${ARGO_NS:-argocd}"

die() { echo "ERROR: $*" >&2; exit 1; }

command -v kubectl >/dev/null || die "kubectl required"
command -v curl >/dev/null || die "curl required"
command -v python3 >/dev/null || die "python3 required (for JSON)"

echo "=== [1] Argo CD admin password from cluster ==="
ADMIN_PW="$(kubectl -n "${ARGO_NS}" get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
[[ -n "${ADMIN_PW}" ]] || die "Could not read argocd-initial-admin-secret in ${ARGO_NS}"

echo "=== [2] Admin session JWT ==="
SESSION_JSON="$(curl -sk -X POST "${ARGOCD_BASE_URL}/api/v1/session" \
  -H 'Content-Type: application/json' \
  -d "{\"username\":\"admin\",\"password\":\"${ADMIN_PW}\"}")"
SESSION_TOKEN="$(python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" <<< "${SESSION_JSON}")"
[[ -n "${SESSION_TOKEN}" ]] || die "Argo session failed: ${SESSION_JSON}"

echo "=== [3] Long-lived admin API token (optional) ==="
API_TOKEN="$(curl -sk -X POST "${ARGOCD_BASE_URL}/api/v1/account/admin/token" \
  -H "Authorization: Bearer ${SESSION_TOKEN}" \
  -H 'Content-Type: application/json' \
  -d "{\"id\":\"paas-$(date +%s)\",\"expiresIn\":31536000}" 2>/dev/null \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
TOKEN="${API_TOKEN:-${SESSION_TOKEN}}"
echo "Using token kind: $([[ -n "${API_TOKEN}" ]] && echo api || echo session), len=${#TOKEN}"

echo "=== [4] Patch PaaS frontend (in-cluster env) ==="
kubectl set env deployment/frontend -n "${PAAS_NS}" \
  ARGOCD_BASE_URL="${ARGOCD_BASE_URL}" \
  ARGOCD_AUTH_TOKEN="${TOKEN}" \
  ARGOCD_TLS_SKIP_VERIFY=true \
  ARGOCD_APP_PREFIX=paas \
  ARGOCD_AUTO_CREATE_APPLICATION=true \
  ARGOCD_APP_PROJECT=default \
  PAAS_STRICT_INTEGRATIONS=false

kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s

echo "=== [5] Verify API (simple-app + sample new app name) ==="
for app in paas-simple-app paas-profit-margin-sponsoring-facebook; do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${TOKEN}" \
    "${ARGOCD_BASE_URL}/api/v1/applications/${app}")"
  echo "GET ${app} → HTTP ${CODE}"
done

echo ""
echo "=== Done ==="
echo "Update paas/frontend/docker-compose.env on the VM too:"
echo "  ARGOCD_BASE_URL=${ARGOCD_BASE_URL}"
echo "  ARGOCD_AUTH_TOKEN=<paste token from: kubectl get deploy frontend -n paas -o yaml | grep ARGOCD_AUTH_TOKEN>"
echo "Then create projects again — Argo panel should show Health/Sync instead of 403."
