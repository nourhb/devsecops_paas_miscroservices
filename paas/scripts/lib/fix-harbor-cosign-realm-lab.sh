#!/usr/bin/env bash
set -euo pipefail
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_NS="${HARBOR_NS:-harbor}"
HARBOR_RELEASE="${HARBOR_RELEASE:-harbor}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
EXTERNAL_URL="http://${HARBOR_HOST}:${HARBOR_NODEPORT}"

if command -v helm >/dev/null 2>&1 && helm status "${HARBOR_RELEASE}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
  helm upgrade "${HARBOR_RELEASE}" harbor/harbor -n "${HARBOR_NS}" --reuse-values \
    --set "externalURL=${EXTERNAL_URL}"
else
  echo "WARN: helm release ${HARBOR_RELEASE} not found in ${HARBOR_NS}" >&2
  exit 1
fi
