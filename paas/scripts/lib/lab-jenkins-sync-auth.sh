#!/usr/bin/env bash
# Lab script to jenkins sync auth on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_USER="${JENKINS_ADMIN_USER:-admin}"
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
  [[ -n "${pw}" ]] || fail "could not read chart-admin-password from ${JENKINS_NS}/jenkins-0"
  printf '%s' "${pw}"
}

try_api_token() {
  local admin_pass="$1"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${admin_pass}" <<'PY' 2>/dev/null || return 1
import base64, json, sys, urllib.error, urllib.parse, urllib.request
base, user, password = sys.argv[1:4]
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
    crumb = {} if e.code == 404 else (_ for _ in ()).throw(e)
crumb_h = {}
if crumb.get("crumb"):
    crumb_h[crumb.get("crumbRequestField", "Jenkins-Crumb")] = crumb["crumb"]
token_url = (
    f"{base.rstrip('/')}/user/{urllib.parse.quote(user)}/descriptorByName/"
    "jenkins.security.ApiTokenProperty/generateNewToken"
)
raw = req(token_url, data=urllib.parse.urlencode({"newTokenName": "paas-lab"}).encode(), extra=crumb_h)
data = json.loads(raw.decode())
token = (data.get("data") or {}).get("tokenValue") or data.get("tokenValue") or ""
if not token:
    sys.exit(1)
print(token)
PY
}

resolve_jenkins_secret() {
  local admin_pass="$1" token verify
  token="$(try_api_token "${admin_pass}" | tr -d '\r\n' || true)"
  if [[ -z "${token}" ]]; then
    warn "API token creation failed — using chart admin password as JENKINS_API_TOKEN"
    token="${admin_pass}"
  fi
  verify="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -u "${JENKINS_USER}:${token}" \
    "${JENKINS_URL}/api/json" 2>/dev/null || echo 000)"
  [[ "${verify}" == "200" ]] || fail "Jenkins auth verify HTTP ${verify} for user ${JENKINS_USER}"
  printf '%s' "${token}"
}

sync_env_files() {
  local token="$1"
  for f in "${DOT_ENV}" "${ENV_FILE}"; do
    patch_env_key "${f}" "JENKINS_BASE_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "JENKINS_PROBE_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "JENKINS_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "NEXT_PUBLIC_JENKINS_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "NEXT_PUBLIC_JENKINS_PROBE_URL" "${JENKINS_URL}"
    patch_env_key "${f}" "JENKINS_USERNAME" "${JENKINS_USER}"
    patch_env_key "${f}" "JENKINS_API_TOKEN" "${token}"
    patch_env_key "${f}" "JENKINS_DEPLOY_JOB_NAME" "paas-deploy"
    patch_env_key "${f}" "JENKINS_BUILD_JOB_NAME" "paas-deploy"
    ok "patched ${f}"
  done
}

verify_pod() {
  local user
  user="$(kubectl exec -n paas deploy/frontend -- printenv JENKINS_USERNAME 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "${user}" != "${JENKINS_USER}" ]]; then
    fail "pod JENKINS_USERNAME=${user:-<unset>} expected ${JENKINS_USER} — re-run: bash paas/scripts/lab.sh env-quick"
  fi
  ok "pod JENKINS_USERNAME=${user}"
}

main() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
  command -v curl >/dev/null 2>&1 || fail "curl required"

  echo "==> jenkins-sync-auth (${JENKINS_URL}, user=${JENKINS_USER})"
  [[ -f "${DOT_ENV}" ]] || fail "missing ${DOT_ENV} — create from .env.example first"

  local admin_pass token
  admin_pass="$(read_chart_admin_password)"
  ok "read chart admin password (${#admin_pass} chars)"
  token="$(resolve_jenkins_secret "${admin_pass}")"
  ok "Jenkins API auth verified (${#token} chars)"

  sync_env_files "${token}"

  echo "==> env-quick (regenerate docker-compose.env from .env + sync pod)"
  PAAS_SKIP_DT=1 bash "${SCRIPT_DIR}/../lab.sh" env-quick

  verify_pod

  echo ""
  echo "Done. Deploy from PaaS UI — Jenkins trigger should return HTTP 201 (not 401)."
  echo "  Jenkins: ${JENKINS_URL}/job/paas-deploy/"
}

main "$@"
