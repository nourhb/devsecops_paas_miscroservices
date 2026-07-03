#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_USER="${JENKINS_ADMIN_USER:-admin}"
JENKINS_TOKEN_NAME="${JENKINS_TOKEN_NAME:-paas-lab}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
JENKINS_URL="http://${NODE_IP}:${JENKINS_NODEPORT}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

patch_env_key() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" ]] || touch "${file}"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

read_chart_admin_password() {
  local pw
  pw="$(kubectl exec -n "${JENKINS_NS}" jenkins-0 -c jenkins --request-timeout=60s \
    cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r\n' || true)"
  [[ -n "${pw}" ]] || pw="$(kubectl exec -n "${JENKINS_NS}" svc/jenkins -c jenkins --request-timeout=60s \
    cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r\n' || true)"
  [[ -n "${pw}" ]] || fail "could not read chart-admin-password from jenkins pod in ${JENKINS_NS}"
  printf '%s' "${pw}"
}

wait_jenkins_up() {
  local n=0 code
  until [[ "${n}" -gt 36 ]]; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "${JENKINS_URL}/login" 2>/dev/null || echo 000)"
    [[ "${code}" =~ ^(200|403)$ ]] && { ok "Jenkins UP ${JENKINS_URL} (HTTP ${code})"; return 0; }
    n=$((n + 1))
    echo "  waiting Jenkins (${n}/36) HTTP ${code}…"
    sleep 10
  done
  fail "Jenkins not up at ${JENKINS_URL}"
}

create_api_token_from_host() {
  local admin_pass="$1" token_name="${2:-${JENKINS_TOKEN_NAME}}"
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${admin_pass}" "${token_name}" <<'PY'
import base64, json, sys, urllib.error, urllib.parse, urllib.request
base, user, password, name = sys.argv[1:5]
auth = base64.b64encode(f"{user}:{password}".encode()).decode()
headers = {"Authorization": f"Basic {auth}"}

def req(url, data=None, extra=None):
    h = dict(headers)
    if extra:
        h.update(extra)
    if data is not None:
        h["Content-Type"] = "application/x-www-form-urlencoded"
    r = urllib.request.Request(url, data=data, headers=h, method="POST" if data is not None else "GET")
    with urllib.request.urlopen(r, timeout=30) as resp:
        return resp.read()

try:
    crumb = json.loads(req(f"{base.rstrip('/')}/crumbIssuer/api/json"))
except urllib.error.HTTPError as e:
    if e.code == 404:
        crumb = {}
    else:
        body = e.read().decode(errors="replace")[:500]
        sys.exit(f"FAIL: crumb HTTP {e.code}: {body}")
crumb_h = {}
if crumb.get("crumb"):
    crumb_h[crumb.get("crumbRequestField", "Jenkins-Crumb")] = crumb["crumb"]

token_url = (
    f"{base.rstrip('/')}/user/{urllib.parse.quote(user)}/descriptorByName/"
    "jenkins.security.ApiTokenProperty/generateNewToken"
)
body = urllib.parse.urlencode({"newTokenName": name}).encode()
try:
    raw = req(token_url, data=body, extra=crumb_h)
except urllib.error.HTTPError as e:
    body = e.read().decode(errors="replace")[:500]
    sys.exit(f"FAIL: token HTTP {e.code}: {body}")
data = json.loads(raw.decode())
token = (data.get("data") or {}).get("tokenValue") or data.get("tokenValue") or ""
if not token:
    sys.exit(f"FAIL: no tokenValue in response: {raw[:300]!r}")
print(token)
PY
}

create_api_token_in_pod() {
  local token_name="${1:-${JENKINS_TOKEN_NAME}}"
  kubectl exec -i -n "${JENKINS_NS}" jenkins-0 -c jenkins --request-timeout=120s -- bash -s "${token_name}" <<'EOS'
set -euo pipefail
TOKEN_NAME="${1:-paas-lab}"
APW="$(tr -d '\r\n' < /run/secrets/additional/chart-admin-password)"
BASE="http://127.0.0.1:8080"
code="$(curl -sS -o /dev/null -w '%{http_code}' -u "admin:${APW}" "${BASE}/api/json" || echo 000)"
if [[ "${code}" != "200" ]]; then
  echo "FAIL: admin password invalid inside pod (HTTP ${code})" >&2
  exit 1
fi
CRUMB_JSON="$(curl -sS -u "admin:${APW}" "${BASE}/crumbIssuer/api/json" 2>/dev/null || true)"
CRUMB="$(printf '%s' "${CRUMB_JSON}" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
FIELD="$(printf '%s' "${CRUMB_JSON}" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')"
FIELD="${FIELD:-Jenkins-Crumb}"
HDR=(-H "Content-Type: application/x-www-form-urlencoded")
[[ -n "${CRUMB}" ]] && HDR+=(-H "${FIELD}:${CRUMB}")
RESP="$(curl -sS -u "admin:${APW}" "${HDR[@]}" -X POST \
  "${BASE}/user/admin/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken" \
  --data-urlencode "newTokenName=${TOKEN_NAME}")"
TOKEN="$(printf '%s' "${RESP}" | sed -n 's/.*"tokenValue":"\([^"]*\)".*/\1/p')"
if [[ -z "${TOKEN}" ]]; then
  echo "FAIL: token response: ${RESP}" >&2
  exit 1
fi
printf '%s\n' "${TOKEN}"
EOS
}

create_api_token() {
  local admin_pass="$1" token
  if token="$(create_api_token_from_host "${admin_pass}" "${JENKINS_TOKEN_NAME}" 2>/dev/null | tr -d '\r\n' | tail -1)" \
    && [[ -n "${token}" && "${token}" != FAIL:* ]]; then
    printf '%s' "${token}"
    return 0
  fi
  warn "host token API failed — trying inside jenkins pod"
  token="$(create_api_token_in_pod "${JENKINS_TOKEN_NAME}" 2>/dev/null | tr -d '\r\n' | tail -1 || true)"
  if [[ -n "${token}" && "${token}" != FAIL:* ]]; then
    printf '%s' "${token}"
    return 0
  fi
  warn "token API failed — using chart admin password as JENKINS_API_TOKEN (valid for Jenkins Basic auth)"
  printf '%s' "${admin_pass}"
}

sync_env() {
  local token="$1"
  for f in "${ENV_FILE}" "${DOT_ENV}"; do
    patch_env_key "${f}" "JENKINS_BASE_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "JENKINS_PROBE_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "JENKINS_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "JENKINS_USERNAME" "${JENKINS_USER}"
    patch_env_key "${f}" "JENKINS_API_TOKEN" "${token}"
    ok "updated ${f}"
  done
}

main() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
  command -v curl >/dev/null 2>&1 || fail "curl required"
  command -v python3 >/dev/null 2>&1 || fail "python3 required"

  echo "=============================================="
  echo " jenkins-bootstrap (fresh install → API token)"
  echo "=============================================="

  wait_jenkins_up
  local admin_pass token verify
  admin_pass="$(read_chart_admin_password)"
  ok "read helm chart admin password (${#admin_pass} chars)"

  token="$(create_api_token "${admin_pass}")" || fail "API token creation failed"
  ok "API token created (${#token} chars)"

  verify="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -u "${JENKINS_USER}:${token}" \
    "${JENKINS_URL}/api/json" 2>/dev/null || echo 000)"
  [[ "${verify}" == "200" ]] || fail "token verify HTTP ${verify} — login at ${JENKINS_URL} as admin"

  sync_env "${token}"

  export JENKINS_USERNAME="${JENKINS_USER}" JENKINS_API_TOKEN="${token}"
  export JENKINS_PROBE_URL="${JENKINS_URL}" JENKINS_BASE_URL="${JENKINS_URL}"

  if [[ -f "${SCRIPT_DIR}/install-jenkins-stages-file.sh" ]]; then
    bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh" || warn "stages install failed — bundle may already be on pod"
  fi
  bash "${SCRIPT_DIR}/lab-jenkins-pipeline-plugins.sh" || \
    bash "${SCRIPT_DIR}/install-jenkins-workflow-plugins.sh" || \
    fail "Pipeline plugins required for paas-deploy job"
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force || fail "paas-deploy job create failed"
  python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py" || warn "wrapper POST failed"
  PAAS_SKIP_DT=1 bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || warn "env sync failed"

  echo "=============================================="
  echo "Done."
  echo "  Jenkins UI:  ${JENKINS_URL}"
  echo "  Login:       ${JENKINS_USER} / (helm chart password — not saved in env)"
  echo "  API user:    ${JENKINS_USER}  token in docker-compose.env"
  echo "  Job:         ${JENKINS_URL}/job/paas-deploy/"
  echo "  Next:        trigger deploy from PaaS UI"
  echo "=============================================="
}

main "$@"
