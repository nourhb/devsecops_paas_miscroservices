#!/usr/bin/env bash
# Reduce 502 on large crane blob PATCH via Harbor nginx (lab).
set -euo pipefail

HARBOR_NS="${HARBOR_NS:-harbor}"
CM=""
for name in harbor-nginx nginx; do
  if kubectl get configmap "${name}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    CM="${name}"
    break
  fi
done

if [[ -z "${CM}" ]]; then
  echo "WARN: no harbor nginx configmap — skip upload timeout patch"
  exit 0
fi

echo "==> Patch ${CM} (client_max_body_size + proxy timeouts for large layers)"
kubectl get configmap "${CM}" -n "${HARBOR_NS}" -o yaml | grep -q 'paas-large-upload-20260604' && {
  echo "OK: already patched"
  exit 0
}

# Harbor helm embeds nginx.conf in configmap; append a server snippet if supported.
if kubectl get configmap "${CM}" -n "${HARBOR_NS}" -o jsonpath='{.data.nginx\.conf}' >/dev/null 2>&1; then
  tmp="$(mktemp)"
  kubectl get configmap "${CM}" -n "${HARBOR_NS}" -o jsonpath='{.data.nginx\.conf}' >"${tmp}"
  if ! grep -q 'client_max_body_size 0' "${tmp}"; then
    sed -i 's/client_max_body_size[^;]*;/client_max_body_size 0;/' "${tmp}" 2>/dev/null || true
    if ! grep -q 'client_max_body_size' "${tmp}"; then
      sed -i 's/http {/http {\n    client_max_body_size 0;\n    proxy_read_timeout 900s;\n    proxy_send_timeout 900s;/' "${tmp}"
    fi
    kubectl create configmap "${CM}" -n "${HARBOR_NS}" --from-file=nginx.conf="${tmp}" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
    echo "OK: nginx.conf client_max_body_size / timeouts adjusted (if sed matched)"
  fi
  rm -f "${tmp}"
fi

kubectl rollout restart deployment/harbor-nginx -n "${HARBOR_NS}" 2>/dev/null || true
kubectl rollout status deployment/harbor-nginx -n "${HARBOR_NS}" --timeout=180s 2>/dev/null || true
echo "OK: harbor-nginx restarted (paas-large-upload-20260604)"
