#!/usr/bin/env bash
# POST paas-deploy config.xml to Jenkins REST API so the running job reloads (disk-only edits are ignored).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JOB="${JENKINS_JOB_NAME:-paas-deploy}"
JOB_CFG="/var/jenkins_home/jobs/${JOB}/config.xml"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:30090}"
CPS_MARKER="${PAAS_DEPLOY_STAGES_LOAD_MARKER:-paas-deploy-stages-load-20260620-cps-split}"
TMP_CFG="${TMP_CFG:-/tmp/paas-deploy-config.xml}"

load_jenkins_creds() {
  if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      case "${line%%=*}" in
        JENKINS_USERNAME|JENKINS_API_TOKEN|JENKINS_USER|JENKINS_TOKEN|JENKINS_BASE_URL|JENKINS_PROBE_URL)
          export "${line}"
          ;;
      esac
    done < "${ENV_FILE}"
  fi
  [[ -z "${JENKINS_USERNAME:-}" && -n "${JENKINS_USER:-}" ]] && export JENKINS_USERNAME="${JENKINS_USER}"
  [[ -z "${JENKINS_API_TOKEN:-}" && -n "${JENKINS_TOKEN:-}" ]] && export JENKINS_API_TOKEN="${JENKINS_TOKEN}"
  if [[ -n "${JENKINS_BASE_URL:-}" ]]; then
    JENKINS_URL="${JENKINS_BASE_URL%/}"
  elif [[ -n "${JENKINS_PROBE_URL:-}" ]]; then
    JENKINS_URL="${JENKINS_PROBE_URL%/}"
  fi
}

load_jenkins_creds
[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
}

echo "==> reload-jenkins-paas-deploy-job (POST live config to ${JENKINS_URL}/job/${JOB}/)"

kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  cat "${JOB_CFG}" > "${TMP_CFG}"

CRUMB_JSON="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || true)"
CRUMB=""
CRUMB_FIELD=""
if [[ -n "${CRUMB_JSON}" ]] && command -v python3 >/dev/null 2>&1; then
  CRUMB="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("crumb",""))' <<< "${CRUMB_JSON}" 2>/dev/null || true)"
  CRUMB_FIELD="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("crumbRequestField","Jenkins-Crumb"))' <<< "${CRUMB_JSON}" 2>/dev/null || true)"
fi

HTTP_CODE=""
if [[ -n "${CRUMB}" ]]; then
  HTTP_CODE="$(curl -sS -o /tmp/jenkins-reload-body.txt -w '%{http_code}' \
    -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    -X POST \
    -H "Content-Type: application/xml; charset=UTF-8" \
    -H "${CRUMB_FIELD}: ${CRUMB}" \
    --data-binary @"${TMP_CFG}" \
    "${JENKINS_URL}/job/${JOB}/config.xml")"
else
  HTTP_CODE="$(curl -sS -o /tmp/jenkins-reload-body.txt -w '%{http_code}' \
    -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    -X POST \
    -H "Content-Type: application/xml; charset=UTF-8" \
    --data-binary @"${TMP_CFG}" \
    "${JENKINS_URL}/job/${JOB}/config.xml")"
fi

if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "201" ]]; then
  echo "WARN: Jenkins POST config.xml HTTP ${HTTP_CODE} — restarting Jenkins pod"
  kubectl rollout restart deploy/jenkins -n "${JENKINS_NS}"
  kubectl rollout status deploy/jenkins -n "${JENKINS_NS}" --timeout=300s
else
  echo "OK: Jenkins accepted config.xml (HTTP ${HTTP_CODE})"
fi

LIVE_MARKER="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null \
  | grep -o 'paas-deploy-stages-load-[0-9a-z-]*' | head -1 || true)"

if [[ "${LIVE_MARKER}" != "${CPS_MARKER}" ]]; then
  echo "FAIL: Jenkins LIVE job marker='${LIVE_MARKER:-<empty>}' expected '${CPS_MARKER}'" >&2
  echo "      (disk may differ — builds use Jenkins memory until reloaded)" >&2
  exit 1
fi

echo "OK: Jenkins LIVE job marker=${LIVE_MARKER}"
curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null | grep -qF 'load paasLoadH1' && echo OK:live-multi-load
curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null | grep -qF 'runPaasDeploy()' && echo OK:live-run-call
