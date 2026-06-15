#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_NS="${HARBOR_NS:-harbor}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
REGISTRY="${HARBOR_HOST}:${HARBOR_NODEPORT}"
PROBE_URL="http://${REGISTRY}/v2/"

probe_harbor() {
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 "${PROBE_URL}" 2>/dev/null || echo "000"
}

echo "==> Harbor registry recover (${REGISTRY})"
bash "${SCRIPT_DIR}/normalize-harbor-env-lab.sh" || true
bash "${SCRIPT_DIR}/fix-harbor-cosign-realm-lab.sh" || true

hc="$(probe_harbor)"
if [[ "${hc}" == "200" || "${hc}" == "401" ]]; then
  echo "OK: Harbor /v2/ already healthy (HTTP ${hc})"
  exit 0
fi

echo "Harbor /v2/ HTTP ${hc} — restarting core registry workloads"
kubectl get pods -n "${HARBOR_NS}" -o wide 2>/dev/null || true

for deploy in harbor-nginx harbor-registry harbor-core; do
  if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    echo "==> rollout restart deployment/${deploy} -n ${HARBOR_NS}"
    kubectl rollout restart "deployment/${deploy}" -n "${HARBOR_NS}" || true
  fi
done

for deploy in harbor-nginx harbor-registry harbor-core; do
  if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    kubectl rollout status "deployment/${deploy}" -n "${HARBOR_NS}" --timeout=300s || true
  fi
done

for i in $(seq 1 30); do
  hc="$(probe_harbor)"
  if [[ "${hc}" == "200" || "${hc}" == "401" ]]; then
    echo "OK: Harbor /v2/ recovered (HTTP ${hc}) at ${PROBE_URL}"
    exit 0
  fi
  echo "wait ${i}/30 — Harbor /v2/ HTTP ${hc}"
  sleep 10
done

echo "ERROR: Harbor still unhealthy at ${PROBE_URL}" >&2
kubectl get pods -n "${HARBOR_NS}" 2>/dev/null || true
kubectl get events -n "${HARBOR_NS}" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
exit 1
