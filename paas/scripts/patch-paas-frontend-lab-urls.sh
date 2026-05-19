#!/usr/bin/env bash
# PaaS UI shows http://simple-app.apps.local — set nip.io env on in-cluster frontend.
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_NS="${PAAS_NS:-paas}"

kubectl set env deployment/frontend -n "${PAAS_NS}" \
  APPS_PUBLIC_LAB_NODE_IP="${NODE_IP}" \
  APPS_PUBLIC_INGRESS_HTTP_PORT="30659" \
  APPS_PUBLIC_URL_SCHEME="http" \
  APPS_PUBLIC_BASE_DOMAIN="apps.local"

kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s
echo "App links should now use: http://<project>.${NODE_IP}.nip.io:30659/"
echo "Rebuild/redeploy from PaaS UI after this; old deployment rows may still show apps.local."
