#!/usr/bin/env bash
# Test Harbor registry reachability from the Jenkins pod (same network as paas-deploy builds).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
JENKINS_DEPLOY="${JENKINS_DEPLOY:-jenkins}"
HARBOR_NS="${HARBOR_NS:-harbor}"

[[ -f "${ENV_FILE}" ]] || { echo "FAIL: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u

bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}" >/dev/null
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true

PUSH="${HARBOR_REGISTRY_PUSH:-${HARBOR_REGISTRY_NGINX_CLUSTER:-}}"
REG_DIRECT="${HARBOR_REGISTRY_CLUSTER:-}"
EXT="${HARBOR_REGISTRY:-192.168.56.129:30002}"

echo "HARBOR_REGISTRY=${EXT}"
echo "HARBOR_REGISTRY_PUSH=${PUSH:-<unset>}"
echo "HARBOR_REGISTRY_CLUSTER=${REG_DIRECT:-<unset>}"

kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" >/dev/null 2>&1 || {
  echo "FAIL: no deployment/${JENKINS_DEPLOY} in ${JENKINS_NS}" >&2
  exit 1
}

echo ""
echo "==> Harbor registry pod"
kubectl get pods -n "${HARBOR_NS}" -l app=harbor,component=registry -o wide 2>/dev/null || true

probe() {
  local label="$1" host="$2"
  echo ""
  echo "==> From Jenkins pod → ${label} (${host})"
  kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- \
    curl -sS -o /dev/null -w "HTTP %{http_code}\n" --connect-timeout 8 --max-time 20 \
    "http://${host}/v2/" 2>/dev/null || echo "HTTP 000"
}

code_for() {
  local host="$1"
  kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- \
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
    "http://${host}/v2/" 2>/dev/null || echo 000
}

ok_code() {
  [[ "$1" == "200" || "$1" == "401" ]]
}

probe "external NodePort" "${EXT}"
code_ext="$(code_for "${EXT}")"

code_push="000"
if [[ -n "${PUSH}" ]]; then
  probe "in-cluster push (nginx)" "${PUSH}"
  code_push="$(code_for "${PUSH}")"
fi

if ! ok_code "${code_push}" && [[ -n "${REG_DIRECT}" && "${REG_DIRECT}" != "${PUSH}" ]]; then
  probe "raw registry (fallback)" "${REG_DIRECT}"
  code_reg="$(code_for "${REG_DIRECT}")"
  if ok_code "${code_reg}"; then
    echo "WARN: nginx push unreachable but registry:5000 works — rare; prefer fixing nginx"
    code_push="${code_reg}"
  fi
fi

if ok_code "${code_push}"; then
  echo ""
  echo "OK: Jenkins can reach Harbor for crane push (${PUSH})"
  exit 0
fi

echo ""
echo "FAIL: Jenkins cannot reach a working in-cluster Harbor /v2/" >&2
echo "  NodePort HTTP ${code_ext}; push HTTP ${code_push}" >&2
echo "  Fix: bash paas/scripts/recover-harbor-registry-lab.sh" >&2
echo "       kubectl logs -n harbor deploy/harbor-registry --all-containers --tail=50" >&2
echo "       kubectl logs -n harbor deploy/harbor-core --tail=30" >&2
exit 1
