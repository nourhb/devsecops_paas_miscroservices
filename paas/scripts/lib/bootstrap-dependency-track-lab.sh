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
API_POD=""
API_BASE=""

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

read_env_val() {
  local key="$1" file line
  for file in "${ENV_FILE}" "${DOT_ENV}"; do
    [[ -f "${file}" ]] || continue
    line="$(grep -E "^${key}=" "${file}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' || true)"
    [[ -n "${line}" ]] && printf '%s' "${line}" && return 0
  done
  return 1
}

load_dt_admin_creds() {
  local from_env
  from_env="$(read_env_val DT_ADMIN_USER || true)"
  [[ -n "${from_env}" ]] && DT_ADMIN_USER="${from_env}"
  from_env="$(read_env_val DT_ADMIN_PASSWORD || true)"
  [[ -n "${from_env}" ]] && DT_ADMIN_PASSWORD="${from_env}"
  from_env="$(read_env_val DT_ADMIN_NEW_PASSWORD || true)"
  [[ -n "${from_env}" ]] && DT_ADMIN_NEW_PASSWORD="${from_env}"
}

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

ensure_helm_repo() {
  helm repo add dependency-track https://dependencytrack.github.io/helm-charts 2>/dev/null || true
  helm repo update dependency-track 2>/dev/null || helm repo update 2>/dev/null || true
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

api_pod_name() {
  kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server \
    -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | awk '{print $1}'
}

setup_api_pod() {
  local pod
  pod="$(api_pod_name)"
  if [[ -z "${pod}" ]]; then
    warn "no Running DT API pod in ${DT_NS}"
    return 0
  fi
  if kubectl exec -n "${DT_NS}" "${pod}" --request-timeout=20s -- \
    curl -fsS -m 5 "http://127.0.0.1:8080/api/version" >/dev/null 2>&1; then
    API_POD="${pod}"
    ok "using in-pod API (${pod}:8080)"
  fi
}

dt_http() {
  local method="$1" path="$2"
  shift 2
  if [[ -n "${API_POD}" ]]; then
    kubectl exec -n "${DT_NS}" "${API_POD}" --request-timeout=45s -- \
      curl -sS -m 30 -X "${method}" "http://127.0.0.1:8080${path}" "$@"
    return $?
  fi
  curl -sS -m 30 -X "${method}" "${API_BASE}${path}" "$@"
}

wait_api() {
  local n=0 pod
  until curl -fsS -m 5 "${API_BASE}/api/version" >/dev/null 2>&1 \
    || { [[ -n "${API_POD}" ]] && dt_http GET "/api/version" >/dev/null 2>&1; }; do
    n=$((n + 1))
    if [[ "${n}" -eq 3 ]]; then
      setup_api_pod
      if [[ -n "${API_POD}" ]] && dt_http GET "/api/version" >/dev/null 2>&1; then
        ok "API ready via pod ${API_POD}"
        return 0
      fi
    fi
    if [[ "${n}" -eq 8 ]]; then
      pod="$(api_pod_name)"
      if [[ -n "${pod}" ]]; then
        echo "==> NodePort unreachable — port-forward pod/${pod}"
        kubectl port-forward -n "${DT_NS}" "pod/${pod}" "127.0.0.1:32399:8080" >/tmp/dt-bootstrap-pf.log 2>&1 &
        DT_PF_PID=$!
        sleep 4
        API_BASE="http://127.0.0.1:32399"
        API_POD=""
        if curl -fsS -m 5 "${API_BASE}/api/version" >/dev/null 2>&1; then
          ok "API ready via port-forward ${API_BASE}/api/version"
          return 0
        fi
      fi
    fi
    [[ "${n}" -le 30 ]] || fail "API not ready at ${API_BASE}/api/version (kubectl get pods -n ${DT_NS})"
    sleep 5
  done
  ok "API ready ${API_BASE}/api/version"
}

DT_PF_PID=""
cleanup_dt_pf() {
  [[ -n "${DT_PF_PID:-}" ]] && kill "${DT_PF_PID}" 2>/dev/null || true
}
trap cleanup_dt_pf EXIT

dt_login_raw() {
  local user="$1" pass="$2"
  dt_http POST "/api/v1/user/login" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -w $'\n__HTTP__%{http_code}' \
    --data-urlencode "username=${user}" \
    --data-urlencode "password=${pass}"
}

parse_login() {
  local raw="$1"
  LOGIN_HTTP="${raw##*$'\n__HTTP__'}"
  LOGIN_BODY="${raw%$'\n__HTTP__'*}"
}

normalize_bearer_token() {
  printf '%s' "${1}" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)
if raw.startswith("{"):
    obj = json.loads(raw)
    for k in ("token", "accessToken", "jwt"):
        if obj.get(k):
            print(obj[k])
            raise SystemExit(0)
print(raw)
'
}

acquire_token() {
  local raw pass tried="" token
  for pass in "DependencyTrack123!" "admin" "${DT_ADMIN_NEW_PASSWORD}" "${DT_ADMIN_PASSWORD}"; do
    [[ -n "${pass}" ]] || continue
    case " ${tried} " in *" ${pass} "*) continue ;; esac
    tried="${tried} ${pass}"
    echo "==> DT login user=${DT_ADMIN_USER} (trying password len=${#pass})"
    raw="$(dt_login_raw "${DT_ADMIN_USER}" "${pass}")"
    parse_login "${raw}"
    if [[ "${LOGIN_HTTP}" == "200" && -n "${LOGIN_BODY}" && "${LOGIN_BODY}" != *"FORCE_PASSWORD_CHANGE"* ]]; then
      token="$(normalize_bearer_token "${LOGIN_BODY}")"
      DT_ADMIN_PASSWORD="${pass}"
      patch_env_key "${ENV_FILE}" "DT_ADMIN_PASSWORD" "${pass}"
      patch_env_key "${DOT_ENV}" "DT_ADMIN_PASSWORD" "${pass}"
      ok "logged in as ${DT_ADMIN_USER}"
      printf '%s' "${token}"
      return 0
    fi
    if [[ "${LOGIN_BODY}" == *"FORCE_PASSWORD_CHANGE"* ]]; then
      ok "first login — forcing password change to ${DT_ADMIN_NEW_PASSWORD}"
      force_change_password "${DT_ADMIN_USER}" "${pass}" "${DT_ADMIN_NEW_PASSWORD}"
      raw="$(dt_login_raw "${DT_ADMIN_USER}" "${DT_ADMIN_PASSWORD}")"
      parse_login "${raw}"
      [[ "${LOGIN_HTTP}" == "200" && -n "${LOGIN_BODY}" ]] || fail "login after password change HTTP ${LOGIN_HTTP}: ${LOGIN_BODY}"
      token="$(normalize_bearer_token "${LOGIN_BODY}")"
      patch_env_key "${ENV_FILE}" "DT_ADMIN_PASSWORD" "${DT_ADMIN_PASSWORD}"
      patch_env_key "${DOT_ENV}" "DT_ADMIN_PASSWORD" "${DT_ADMIN_PASSWORD}"
      printf '%s' "${token}"
      return 0
    fi
    warn "login HTTP ${LOGIN_HTTP} with password len=${#pass} — next candidate"
    if [[ -n "${LOGIN_BODY}" ]]; then
      warn "login body: ${LOGIN_BODY:0:180}"
    fi
  done
  fail "login failed for user ${DT_ADMIN_USER} — open http://${NODE_IP}:$(discover_frontend_port || echo 30212) or set DT_ADMIN_PASSWORD in .env"
}

force_change_password() {
  local user="$1" old="$2" new="$3" body http
  body="$(dt_http POST "/api/v1/user/forceChangePassword" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -w $'\n__HTTP__%{http_code}' \
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
  dt_http GET "/api/v1/team" -H "Authorization: Bearer ${token}" \
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
  local token="$1" team_uuid="$2" resp key http
  resp="$(dt_http PUT "/api/v1/team/${team_uuid}/key" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -w $'\n__HTTP__%{http_code}')"
  http="${resp##*$'\n__HTTP__'}"
  resp="${resp%$'\n__HTTP__'*}"
  if [[ "${http}" != "200" ]]; then
    resp="$(dt_http POST "/api/v1/team/${team_uuid}/key" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      -w $'\n__HTTP__%{http_code}')"
    http="${resp##*$'\n__HTTP__'}"
    resp="${resp%$'\n__HTTP__'*}"
  fi
  key="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("key",""))' <<<"${resp}")"
  [[ -n "${key}" ]] || fail "API key creation failed (HTTP ${http}): ${resp}"
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
    ok "updated ${f} (UI=${api_base}, Jenkins=${in_cluster})"
  done
  if [[ "${SYNC_JENKINS}" == "true" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
    python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force
    ok "Jenkins job parameters synced"
  fi
}

main() {
  load_dt_admin_creds
  need_cmd kubectl
  need_cmd helm
  need_cmd curl
  need_cmd python3

  echo "=============================================="
  echo " bootstrap-dependency-track-lab (CLI only)"
  echo "=============================================="

  ensure_helm_repo
  fix_frontend_api_base_url

  local api_port api_base token team_uuid api_key verify_http
  api_port="$(discover_api_port)"
  api_base="http://${NODE_IP}:${api_port}"
  API_BASE="${api_base}"

  setup_api_pod
  wait_api

  token="$(acquire_token)"

  team_uuid="$(find_team_uuid "${token}")"
  ok "team ${TEAM_NAME} uuid=${team_uuid}"

  api_key="$(create_api_key "${token}" "${team_uuid}")"
  ok "API key created (${#api_key} chars, starts with ${api_key:0:4}...)"

  verify_http="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
    -H "X-Api-Key: ${api_key}" "${API_BASE}/api/v1/project?pageNumber=1&pageSize=1")"
  [[ "${verify_http}" == "200" ]] || fail "API key verify HTTP ${verify_http} against ${API_BASE}"

  sync_env_and_jenkins "${api_base}" "${api_key}"

  echo "=============================================="
  echo "Done. Next on VM:"
  echo "  bash paas/scripts/lab.sh env"
  echo "  Trigger a new paas-deploy build (not Replay)"
  echo "=============================================="
}

main "$@"
