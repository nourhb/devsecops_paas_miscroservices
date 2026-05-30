#!/usr/bin/env bash
# Recover Harbor when crane/Jenkins gets 502 on manifest PUT (nginx → core/registry).
set -euo pipefail

HARBOR_NS="${HARBOR_NS:-harbor}"
NODE_IP="${NODE_IP:-192.168.56.129}"
REGISTRY_PORT="${HARBOR_REGISTRY_PORT:-30002}"

echo "==> Harbor pods"
kubectl get pods -n "${HARBOR_NS}" -o wide || exit 1

echo ""
echo "==> Restart nginx + core (common 502 fix)"
for dep in harbor-nginx harbor-core; do
  if kubectl get deployment "${dep}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    kubectl rollout restart "deployment/${dep}" -n "${HARBOR_NS}"
    kubectl rollout status "deployment/${dep}" -n "${HARBOR_NS}" --timeout=180s || true
    echo "OK: restarted ${dep}"
  fi
done

echo ""
echo "==> Probe registry /v2/"
for i in 1 2 3 4 5; do
  if curl -fsS --connect-timeout 5 --max-time 15 "http://${NODE_IP}:${REGISTRY_PORT}/v2/" >/dev/null 2>&1; then
    echo "OK: http://${NODE_IP}:${REGISTRY_PORT}/v2/ responds"
    exit 0
  fi
  echo "waiting (${i}/5)…"
  sleep 10
done

echo "FAIL: Harbor still not responding on :${REGISTRY_PORT}/v2/"
echo "Check: kubectl logs -n ${HARBOR_NS} deploy/harbor-core --tail=50"
echo "       kubectl logs -n ${HARBOR_NS} deploy/harbor-nginx --tail=50"
exit 1
