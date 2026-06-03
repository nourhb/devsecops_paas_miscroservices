#!/usr/bin/env bash
# Test Harbor registry reachability from the Jenkins pod (same network as paas-deploy builds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
JENKINS_DEPLOY="${JENKINS_DEPLOY:-jenkins}"

[[ -f "${ENV_FILE}" ]] || { echo "FAIL: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u

PUSH="${HARBOR_REGISTRY_PUSH:-${HARBOR_REGISTRY_CLUSTER:-}}"
EXT="${HARBOR_REGISTRY:-192.168.56.129:30002}"
if [[ -z "${PUSH}" ]]; then
  bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}" >/dev/null
  PUSH="$(grep '^HARBOR_REGISTRY_CLUSTER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
fi

echo "HARBOR_REGISTRY=${EXT}"
echo "HARBOR_REGISTRY_PUSH=${PUSH:-<unset>}"

kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" >/dev/null 2>&1 || {
  echo "FAIL: no deployment/${JENKINS_DEPLOY} in ${JENKINS_NS}" >&2
  exit 1
}

probe() {
  local label="$1" host="$2"
  echo ""
  echo "==> From Jenkins pod → ${label} (${host})"
  kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- \
    curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 8 --max-time 20 \
    "http://${host}/v2/" 2>/dev/null || echo "HTTP 000"
}

probe "external NodePort" "${EXT}"
if [[ -n "${PUSH}" ]]; then
  probe "in-cluster push" "${PUSH}"
  code="$(kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- \
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
    "http://${PUSH}/v2/" 2>/dev/null || echo 000)"
  if [[ "${code}" != "200" && "${code}" != "401" ]]; then
    echo "FAIL: Jenkins cannot reach HARBOR_REGISTRY_PUSH (${PUSH})" >&2
    exit 1
  fi
else
  echo "WARN: HARBOR_REGISTRY_PUSH unset — run: bash paas/scripts/fix-harbor-jenkins-crane-push-lab.sh"
  exit 1
fi

echo ""
echo "OK: Jenkins can reach in-cluster Harbor for crane push"
