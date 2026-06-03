#!/usr/bin/env bash
# Test Harbor reachability for paas-deploy (Jenkins pod + optional cluster probe pod).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
JENKINS_DEPLOY="${JENKINS_DEPLOY:-jenkins}"
HARBOR_NS="${HARBOR_NS:-harbor}"
WIRE_ENV="${WIRE_ENV:-0}"

[[ -f "${ENV_FILE}" ]] || { echo "FAIL: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u

if [[ "${WIRE_ENV}" == "1" ]]; then
  bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}" >/dev/null
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
fi

PUSH="${HARBOR_REGISTRY_PUSH:-}"
REG_DIRECT="${HARBOR_REGISTRY_CLUSTER:-}"
EXT="${HARBOR_REGISTRY:-192.168.56.129:30002}"

echo "HARBOR_REGISTRY=${EXT}"
echo "HARBOR_REGISTRY_PUSH=${PUSH:-<empty — NodePort push>}"
echo "HARBOR_REGISTRY_CLUSTER=${REG_DIRECT:-<unset>}"

kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" >/dev/null 2>&1 || {
  echo "FAIL: no deployment/${JENKINS_DEPLOY} in ${JENKINS_NS}" >&2
  exit 1
}

ok_code() {
  [[ "$1" == "200" || "$1" == "401" ]]
}

jenkins_http_code() {
  local host="$1"
  kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- sh -c \
    'if command -v curl >/dev/null 2>&1; then
       curl -sS -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 20 "http://'"${host}"'/v2/" 2>/dev/null || echo 000
     elif command -v wget >/dev/null 2>&1; then
       wget -q -S -O /dev/null "http://'"${host}"'/v2/" 2>&1 | awk "/HTTP\\//{print \$2; exit}" || echo 000
     else
       echo no-http-client
     fi' 2>/dev/null || echo 000
}

cluster_curl_code() {
  local host="$1"
  local pod="harbor-net-probe-$$"
  kubectl delete pod -n "${JENKINS_NS}" "${pod}" --ignore-not-found >/dev/null 2>&1 || true
  if ! kubectl run -n "${JENKINS_NS}" "${pod}" --restart=Never --image=curlimages/curl:8.5.0 \
    --command -- sleep 120 >/dev/null 2>&1; then
    echo 000
    return
  fi
  kubectl wait -n "${JENKINS_NS}" --for=condition=Ready "pod/${pod}" --timeout=90s >/dev/null 2>&1 || true
  local code
  code="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- \
    curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
    "http://${host}/v2/" 2>/dev/null || echo 000)"
  kubectl delete pod -n "${JENKINS_NS}" "${pod}" --ignore-not-found >/dev/null 2>&1 || true
  echo "${code}"
}

probe_jenkins() {
  local label="$1" host="$2"
  echo "" >&2
  echo "==> Jenkins pod → ${label} (${host})" >&2
  local tools
  tools="$(kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- sh -c \
    'command -v curl >/dev/null 2>&1 && echo curl; command -v wget >/dev/null 2>&1 && echo wget' 2>/dev/null || true)"
  echo "    http tools: ${tools:-none}" >&2
  local code
  code="$(jenkins_http_code "${host}")"
  if [[ "${code}" == "no-http-client" ]]; then
    echo "    no curl/wget — will use cluster probe pod" >&2
    echo 000
    return
  fi
  echo "    HTTP ${code}" >&2
  echo "${code}"
}

echo "" >&2
echo "==> Harbor registry pod" >&2
kubectl get pods -n "${HARBOR_NS}" -l app=harbor,component=registry -o wide 2>/dev/null >&2 || true

code_ext="$(probe_jenkins "external NodePort" "${EXT}")"
if ! ok_code "${code_ext}"; then
  echo "    cluster probe pod → NodePort ${EXT}" >&2
  code_ext="$(cluster_curl_code "${EXT}")"
  echo "    HTTP ${code_ext} (curl pod)" >&2
fi

code_push="000"
if [[ -n "${PUSH}" ]]; then
  code_push="$(probe_jenkins "in-cluster push" "${PUSH}")"
  if ! ok_code "${code_push}"; then
    echo "    cluster probe pod → ${PUSH}" >&2
    code_push="$(cluster_curl_code "${PUSH}")"
    echo "    HTTP ${code_push} (curl pod)" >&2
  fi
fi

if ok_code "${code_ext}"; then
  if [[ -n "${PUSH}" ]] && ok_code "${code_push}"; then
    echo ""
    echo "OK: use in-cluster push (${PUSH})"
    exit 0
  fi
  echo ""
  echo "OK: NodePort reachable (HTTP ${code_ext}) — use HARBOR_REGISTRY for crane push"
  echo "     (HARBOR_REGISTRY_PUSH should be empty)"
  exit 0
fi

echo ""
echo "FAIL: Harbor NodePort not healthy (HTTP ${code_ext})" >&2
echo "  bash paas/scripts/recover-harbor-registry-lab.sh" >&2
echo "  bash paas/scripts/free-harbor-disk-lab.sh" >&2
exit 1
