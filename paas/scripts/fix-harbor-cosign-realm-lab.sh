#!/usr/bin/env bash
set -euo pipefail
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_NS="${HARBOR_NS:-harbor}"
HARBOR_RELEASE="${HARBOR_RELEASE:-harbor}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
EXTERNAL_URL="http://${HARBOR_HOST}:${HARBOR_NODEPORT}"

echo "==> Harbor cosign/Kyverno realm fix"
echo "    externalURL=${EXTERNAL_URL}"
echo "    (cosign/go-containerregistry rejects WWW-Authenticate realms with raw private IPs)"

if command -v helm >/dev/null 2>&1 && helm status "${HARBOR_RELEASE}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
  helm upgrade "${HARBOR_RELEASE}" harbor/harbor -n "${HARBOR_NS}" --reuse-values \
    --set "externalURL=${EXTERNAL_URL}"
  echo "OK: helm upgrade ${HARBOR_RELEASE} externalURL"
else
  echo "WARN: helm release ${HARBOR_RELEASE} not found — set Harbor externalURL manually to:"
  echo "      ${EXTERNAL_URL}"
fi

echo ""
echo "Next:"
echo "  1. bash paas/scripts/apply-kyverno-cosign-lab.sh"
echo "  2. Update PaaS env HARBOR_BASE_URL=${EXTERNAL_URL}"
echo "  3. Re-run Jenkins deploy (new image ref uses hostname) OR:"
echo "     bash paas/scripts/heal-project-deploy-lab.sh test-app <build#> 3000"
echo "     (edit ~/gitops/apps/test-app/values.yaml image.repository to ${HARBOR_HOST}:${HARBOR_NODEPORT}/paas/test-app first)"
