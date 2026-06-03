#!/usr/bin/env bash
# Test Harbor reachability for paas-deploy (Jenkins pod + optional cluster probe pod).
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

ok_code() {
  [[ "$1" == "200" || "$1" == "401" ]]
}

# Jenkins LTS image often has no curl — HTTP 000 from kubectl exec is not proof the network is down.
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
  echo ""
  echo "==> Jenkins pod → ${label} (${host})"
  local tools
  tools="$(kubectl exec -n "${JENKINS_NS}" deploy/"${JENKINS_DEPLOY}" -- sh -c \
    'command -v curl >/dev/null 2>&1 && echo curl; command -v wget >/dev/null 2>&1 && echo wget' 2>/dev/null || true)"
  echo "    http tools in jenkins image: ${tools:-none}"
  local code
  code="$(jenkins_http_code "${host}")"
  if [[ "${code}" == "no-http-client" ]]; then
    echo "    skip direct HTTP (no curl/wget in jenkins/jenkins:lts)"
    code="000"
  else
    echo "    HTTP ${code}"
  fi
  echo "${code}"
}

echo ""
echo "==> Harbor registry pod"
kubectl get pods -n "${HARBOR_NS}" -l app=harbor,component=registry -o wide 2>/dev/null || true

code_ext="$(probe_jenkins "external NodePort" "${EXT}")"
if [[ "${code_ext}" == "000" ]]; then
  echo "    cluster probe pod → NodePort ${EXT}"
  code_ext="$(cluster_curl_code "${EXT}")"
  echo "    HTTP ${code_ext} (curl pod in ${JENKINS_NS})"
fi

code_push="000"
if [[ -n "${PUSH}" ]]; then
  code_push="$(probe_jenkins "in-cluster push" "${PUSH}")"
  if [[ "${code_push}" == "000" ]]; then
    echo "    cluster probe pod → ${PUSH}"
    code_push="$(cluster_curl_code "${PUSH}")"
    echo "    HTTP ${code_push} (curl pod in ${JENKINS_NS})"
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
  echo "     (clear HARBOR_REGISTRY_PUSH; Jenkins on master often cannot curl in-cluster DNS)"
  exit 0
fi

echo ""
echo "FAIL: Harbor not reachable from cluster (NodePort HTTP ${code_ext})" >&2
echo "  bash paas/scripts/recover-harbor-registry-lab.sh" >&2
exit 1
