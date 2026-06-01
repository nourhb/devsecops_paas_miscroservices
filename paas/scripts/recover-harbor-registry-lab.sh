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
echo "==> Probe registry /v2/ (401 Unauthorized = registry up; 502 = broken)"
harbor_v2_ok() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 15 \
    "http://${NODE_IP}:${REGISTRY_PORT}/v2/" 2>/dev/null || echo 000)"
  [[ "${code}" == "200" || "${code}" == "401" ]]
}

for i in 1 2 3 4 5; do
  if harbor_v2_ok; then
    echo "OK: http://${NODE_IP}:${REGISTRY_PORT}/v2/ reachable (HTTP 200 or 401)"
    exit 0
  fi
  echo "waiting (${i}/5)…"
  sleep 10
done

echo "FAIL: Harbor not healthy on :${REGISTRY_PORT}/v2/ (expect 401, not 502)"
echo "Check: kubectl logs -n ${HARBOR_NS} deploy/harbor-core --tail=50"
echo "       kubectl logs -n ${HARBOR_NS} deploy/harbor-nginx --tail=50"
exit 1
