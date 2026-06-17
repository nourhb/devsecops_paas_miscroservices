#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
DT_NS="${DT_NS:-dependency-track}"
RELEASE="${DT_RELEASE:-dtrack}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
DT_ADMIN_USER="${DT_ADMIN_USER:-admin}"
DT_ADMIN_PASSWORD="${DT_ADMIN_PASSWORD:-admin}"
DT_ADMIN_NEW_PASSWORD="${DT_ADMIN_NEW_PASSWORD:-DependencyTrack123!}"
TEAM_NAME="${DT_API_TEAM:-Automation}"
SYNC_JENKINS="${SYNC_JENKINS:-true}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 required"
}

discover_api_port() {
  kubectl get svc -n "${DT_NS}" "${RELEASE}-dependency-track-api-server" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true
}

discover_frontend_port() {
  kubectl get svc -n "${DT_NS}" "${RELEASE}-dependency-track-frontend" \
    -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true
}

patch_env_key() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" ]] || touch "${file}"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

fix_frontend_api_base_url() {
  local api_port fe_port api_base current
  api_port="$(discover_api_port)"
  fe_port="$(discover_frontend_port)"
  [[ -n "${api_port}" && "${api_port}" != "null" ]] || fail "API NodePort not found in ${DT_NS}"
  api_base="http://${NODE_IP}:${api_port}"
  current="$(kubectl get deploy -n "${DT_NS}" "${RELEASE}-dependency-track-frontend" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="API_BASE_URL")].value}' 2>/dev/null || true)"
  if [[ "${current}" != "${api_base}" ]]; then
    echo "==> helm upgrade frontend.apiBaseUrl=${api_base}"
    helm upgrade "${RELEASE}" dependency-track/dependency-track -n "${DT_NS}" \
      --reuse-values \
      --set "frontend.apiBaseUrl=${api_base}" \
      --wait --timeout 8m
    kubectl rollout status -n "${DT_NS}" "deployment/${RELEASE}-dependency-track-frontend" --timeout=5m
  fi
  ok "frontend API_BASE_URL=${api_base}"
  ok "UI port ${fe_port:-?} (optional) — CLI uses API ${api_base} directly"
}

dt_curl() {
  local method="$1" path="$2"
  shift 2
  curl -sS -m 30 -X "${method}" "${API_BASE}${path}" "$@"
}

wait_api() {
  local n=0
  until curl -fsS -m 5 "${API_BASE}/api/version" >/dev/null 2>&1; do
    n=$((n + 1))
    [[ "${n}" -le 30 ]] || fail "API not ready at ${API_BASE}/api/version"
    sleep 5
  done
  ok "API ready ${API_BASE}/api/version"
}

dt_login_raw() {
  local user="$1" pass="$2"
  curl -sS -m 30 -w $'\n__HTTP__%{http_code}' -X POST "${API_BASE}/api/v1/user/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}"
}

parse_login() {
  local raw="$1"
  LOGIN_HTTP="${raw##*$'\n__HTTP__'}"
  LOGIN_BODY="${raw%$'\n__HTTP__'*}"
}

acquire_token() {
  local raw
  raw="$(dt_login_raw "${DT_ADMIN_USER}" "${DT_ADMIN_PASSWORD}")"
  parse_login "${raw}"
  if [[ "${LOGIN_HTTP}" == "200" && -n "${LOGIN_BODY}" && "${LOGIN_BODY}" != *"FORCE_PASSWORD_CHANGE"* ]]; then
    printf '%s' "${LOGIN_BODY}"
    return 0
  fi
  if [[ "${LOGIN_BODY}" == *"FORCE_PASSWORD_CHANGE"* ]]; then
    ok "first login — forcing password change"
    force_change_password "${DT_ADMIN_USER}" "${DT_ADMIN_PASSWORD}" "${DT_ADMIN_NEW_PASSWORD}"
    raw="$(dt_login_raw "${DT_ADMIN_USER}" "${DT_ADMIN_PASSWORD}")"
    parse_login "${raw}"
    [[ "${LOGIN_HTTP}" == "200" && -n "${LOGIN_BODY}" ]] || fail "login after password change HTTP ${LOGIN_HTTP}: ${LOGIN_BODY}"
    printf '%s' "${LOGIN_BODY}"
    return 0
  fi
  fail "login failed HTTP ${LOGIN_HTTP}: ${LOGIN_BODY} — try: DT_ADMIN_USER=admin DT_ADMIN_PASSWORD=admin bash paas/scripts/lab.sh dt-bootstrap"
}

force_change_password() {
  local user="$1" old="$2" new="$3" body http
  body="$(curl -sS -m 30 -w $'\n__HTTP__%{http_code}' -X POST "${API_BASE}/api/v1/user/forceChangePassword" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${old}" \
    --data-urlencode "newPassword=${new}" \
    --data-urlencode "confirmPassword=${new}")"
  http="${body##*$'\n__HTTP__'}"
  body="${body%$'\n__HTTP__'*}"
  [[ "${http}" == "200" ]] || fail "forceChangePassword HTTP ${http}: ${body}"
  ok "admin password changed (use DT_ADMIN_PASSWORD=${new} next time)"
  DT_ADMIN_PASSWORD="${new}"
}

find_team_uuid() {
  local token="$1"
  curl -sS -m 30 -H "Authorization: Bearer ${token}" "${API_BASE}/api/v1/team" \
    | python3 -c "
import json, sys
name = sys.argv[1]
teams = json.load(sys.stdin)
for t in teams:
    if t.get('name') == name:
        print(t['uuid'])
        raise SystemExit(0)
for t in teams:
    if t.get('name') in ('Automation', 'Administrators'):
        print(t['uuid'])
        raise SystemExit(0)
if teams:
    print(teams[0]['uuid'])
else:
    raise SystemExit('no teams')
" "${TEAM_NAME}"
}

create_api_key() {
  local token="$1" team_uuid="$2" resp key
  resp="$(curl -sS -m 30 -X PUT "${API_BASE}/api/v1/team/${team_uuid}/key" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json")"
  key="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' <<<"${resp}")"
  [[ -n "${key}" ]] || fail "API key creation failed: ${resp}"
  printf '%s' "${key}"
}

sync_env_and_jenkins() {
  local api_base="$1" api_key="$2" in_cluster
  in_cluster="http://${RELEASE}-dependency-track-api-server.${DT_NS}.svc.cluster.local:8080"
  for f in "${ENV_FILE}" "${DOT_ENV}"; do
    patch_env_key "${f}" "DEPENDENCY_TRACK_BASE_URL" "${api_base}"
    patch_env_key "${f}" "NEXT_PUBLIC_DEPENDENCY_TRACK_URL" "${api_base}"
    patch_env_key "${f}" "JENKINS_DEPENDENCY_TRACK_BASE_URL" "${in_cluster}"
    patch_env_key "${f}" "DEPENDENCY_TRACK_API_KEY" "${api_key}"
    ok "updated ${f}"
  done
  if [[ "${SYNC_JENKINS}" == "true" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
    python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force
    ok "Jenkins job parameters synced"
  fi
}

main() {
  need_cmd kubectl
  need_cmd helm
  need_cmd curl
  need_cmd python3

  echo "=============================================="
  echo " bootstrap-dependency-track-lab (CLI only)"
  echo "=============================================="

  fix_frontend_api_base_url

  local api_port api_base token team_uuid api_key verify_http
  api_port="$(discover_api_port)"
  api_base="http://${NODE_IP}:${api_port}"
  API_BASE="${api_base}"

  wait_api

  token="$(acquire_token)"
  ok "logged in as ${DT_ADMIN_USER}"

  team_uuid="$(find_team_uuid "${token}")"
  ok "team ${TEAM_NAME} uuid=${team_uuid}"

  api_key="$(create_api_key "${token}" "${team_uuid}")"
  ok "API key created (${#api_key} chars, starts with ${api_key:0:4}...)"

  verify_http="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
    -H "X-Api-Key: ${api_key}" "${api_base}/api/v1/project?pageNumber=1&pageSize=1")"
  [[ "${verify_http}" == "200" ]] || fail "API key verify HTTP ${verify_http}"

  sync_env_and_jenkins "${api_base}" "${api_key}"

  echo "=============================================="
  echo "Done. Next on VM:"
  echo "  bash paas/scripts/lab.sh env"
  echo "  Trigger Jenkins build #755+ (Build with Parameters, not Replay)"
  echo "=============================================="
}

main "$@"
