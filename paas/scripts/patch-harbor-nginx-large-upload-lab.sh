#!/usr/bin/env bash
# Reduce 502 on large crane blob PATCH via Harbor nginx (lab). Safe: skip config edit if unsure.
set -euo pipefail

HARBOR_NS="${HARBOR_NS:-harbor}"

if [[ "${HARBOR_NGINX_PATCH_SKIP:-false}" == "true" ]]; then
  echo "SKIP: HARBOR_NGINX_PATCH_SKIP=true"
  exit 0
fi

echo "==> Harbor nginx: no configmap sed (avoid broken nginx.conf); rely on free-harbor-disk + stable Harbor"
echo "    To force restart only: kubectl rollout restart deployment/harbor-nginx -n ${HARBOR_NS}"
exit 0
