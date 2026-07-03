#!/usr/bin/env bash
set -euo pipefail
NODE_IP="${NODE_IP:-192.168.56.129}"
INGRESS_PORT="${APPS_PUBLIC_INGRESS_HTTP_PORT:-30659}"
TRAEFIK_NS="${TRAEFIK_NAMESPACE:-kube-system}"
TRAEFIK_SVC="${TRAEFIK_SERVICE:-traefik}"

echo "==> Fix app routing: Traefik on NodePort ${INGRESS_PORT} (not per-app NodePort)"

while IFS=$'\t' read -r ns name; do
  [[ -n "${ns}" && -n "${name}" ]] || continue
  if [[ "${ns}" == "${TRAEFIK_NS}" && "${name}" == "${TRAEFIK_SVC}" ]]; then
    continue
  fi
  echo "  revert ${ns}/svc/${name} from NodePort ${INGRESS_PORT} → ClusterIP"
  kubectl patch svc "${name}" -n "${ns}" --type merge \
    -p '{"spec":{"type":"ClusterIP","ports":[{"port":80,"targetPort":3000}]}}' 2>/dev/null || \
  kubectl patch svc "${name}" -n "${ns}" -p '{"spec":{"type":"ClusterIP"}}' 2>/dev/null || true
done < <(
  kubectl get svc -A -o json 2>/dev/null | python3 -c "
import json, sys
port = int(sys.argv[1])
for item in json.load(sys.stdin).get('items', []):
    ns = item['metadata']['namespace']
    name = item['metadata']['name']
    for p in item.get('spec', {}).get('ports', []) or []:
        if p.get('nodePort') == port:
            print(ns, name)
            break
" "${INGRESS_PORT}" 2>/dev/null || true
)

if kubectl get svc "${TRAEFIK_SVC}" -n "${TRAEFIK_NS}" >/dev/null 2>&1; then
  current_np="$(kubectl get svc "${TRAEFIK_SVC}" -n "${TRAEFIK_NS}" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}' 2>/dev/null || true)"
  if [[ "${current_np}" != "${INGRESS_PORT}" ]]; then
    echo "==> Patch ${TRAEFIK_NS}/${TRAEFIK_SVC} → NodePort ${INGRESS_PORT}"
    kubectl patch svc "${TRAEFIK_SVC}" -n "${TRAEFIK_NS}" --type merge -p "{
      \"spec\": {
        \"type\": \"NodePort\",
        \"ports\": [{
          \"name\": \"web\",
          \"port\": 80,
          \"protocol\": \"TCP\",
          \"targetPort\": \"web\",
          \"nodePort\": ${INGRESS_PORT}
        }]
      }
    }" 2>/dev/null || kubectl patch svc "${TRAEFIK_SVC}" -n "${TRAEFIK_NS}" -p "{
      \"spec\": {\"type\": \"NodePort\", \"ports\": [{\"port\": 80, \"targetPort\": 80, \"nodePort\": ${INGRESS_PORT}}]}
    }" 2>/dev/null || echo "WARN: could not patch Traefik — check: kubectl get svc -n ${TRAEFIK_NS}"
  else
    echo "OK: Traefik already on NodePort ${INGRESS_PORT}"
  fi
else
  echo "WARN: Traefik service ${TRAEFIK_NS}/${TRAEFIK_SVC} not found (k3s default is kube-system/traefik)"
fi

echo ""
echo "==> Ingress resources (host → backend)"
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,HOSTS:.spec.rules[*].host,CLASS:.spec.ingressClassName' 2>/dev/null || true
echo ""
echo "Test (each host should show its own app):"
echo "  curl -s -o /dev/null -w '%{http_code}' -H 'Host: simple-app.${NODE_IP}.nip.io' http://${NODE_IP}:${INGRESS_PORT}/"
echo "  curl -s -o /dev/null -w '%{http_code}' -H 'Host: angular-docker.${NODE_IP}.nip.io' http://${NODE_IP}:${INGRESS_PORT}/"
