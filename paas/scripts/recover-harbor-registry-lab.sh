#!/usr/bin/env bash
# Recover Harbor when crane/Jenkins gets 502 on manifest PUT (nginx → core/registry).
set -euo pipefail

HARBOR_NS="${HARBOR_NS:-harbor}"
NODE_IP="${NODE_IP:-192.168.56.129}"
REGISTRY_PORT="${HARBOR_REGISTRY_PORT:-30002}"

echo "==> Harbor pods"
kubectl get pods -n "${HARBOR_NS}" -o wide || exit 1

echo ""
echo "==> Disk on registry PVC (full disk → 502 on blob upload)"
for claim in $(kubectl get pvc -n "${HARBOR_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  echo "  PVC ${claim}:"
  kubectl get pvc -n "${HARBOR_NS}" "${claim}" -o custom-columns=STATUS:.status.phase,SIZE:.status.capacity.storage 2>/dev/null || true
done
if kubectl get deployment harbor-registry -n "${HARBOR_NS}" >/dev/null 2>&1; then
  kubectl exec -n "${HARBOR_NS}" deploy/harbor-registry -- df -h /storage 2>/dev/null \
    || kubectl exec -n "${HARBOR_NS}" deploy/harbor-registry -- df -h / 2>/dev/null \
    || echo "WARN: could not df inside harbor-registry"
fi

echo ""
echo "==> Wait for harbor-registry 2/2 Ready before restart storm"
if kubectl get deployment harbor-registry -n "${HARBOR_NS}" >/dev/null 2>&1; then
  kubectl wait --for=condition=available deployment/harbor-registry -n "${HARBOR_NS}" --timeout=120s 2>/dev/null \
    || echo "WARN: harbor-registry deployment not Available yet"
fi

echo ""
if [[ "${HARBOR_RECOVER_LIGHT:-0}" == "1" ]]; then
  echo "==> Light mode (HARBOR_RECOVER_LIGHT=1) — probe only, no restarts"
else
echo "==> Restart registry + nginx + core (502 on PATCH/POST /v2/.../blobs/uploads/)"
for dep in harbor-registry harbor-nginx harbor-core; do
  if kubectl get deployment "${dep}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    kubectl rollout restart "deployment/${dep}" -n "${HARBOR_NS}"
    kubectl rollout status "deployment/${dep}" -n "${HARBOR_NS}" --timeout=240s || true
    echo "OK: restarted ${dep}"
  fi
done
fi

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
    echo ""
    echo "Large crane pushes: keep HARBOR_REGISTRY_PUSH empty (NodePort from Jenkins on master)."
    echo "  worker2 disk ~90% → SSH worker2: docker system prune -af; sudo crictl rmi --prune"
    if df -h / 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); if ($5+0 >= 85) print}' | grep -q .; then
      echo "WARN: root disk >= 85% full — prune images/logs or expand disk (Harbor blob upload may fail)"
    fi
    exit 0
  fi
  echo "waiting (${i}/5)…"
  sleep 10
done

echo "FAIL: Harbor not healthy on :${REGISTRY_PORT}/v2/ (expect 401, not 502)"
echo "Check: kubectl logs -n ${HARBOR_NS} deploy/harbor-core --tail=50"
echo "       kubectl logs -n ${HARBOR_NS} deploy/harbor-registry --tail=50"
echo "       kubectl logs -n ${HARBOR_NS} deploy/harbor-nginx --tail=50"
exit 1
