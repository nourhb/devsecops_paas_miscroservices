#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
SONAR_ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_PASSWORD:-admin}"
SONAR_ADMIN_NEW_PASSWORD="${SONAR_ADMIN_NEW_PASSWORD:-SonarQube123!}"
SONAR_TOKEN_NAME="${SONAR_TOKEN_NAME:-paas-jenkins-lab}"
SYNC_JENKINS="${SYNC_JENKINS:-true}"

SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"

ok() { echo "OK: $*" >&2; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 required"
}

patch_env_key() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" ]] || touch "${file}"
  export _PAAS_PATCH_KEY="${key}" _PAAS_PATCH_VAL="${value}" _PAAS_PATCH_FILE="${file}"
  python3 - <<'PY'
import os
from pathlib import Path
f = Path(os.environ["_PAAS_PATCH_FILE"])
key = os.environ["_PAAS_PATCH_KEY"]
val = os.environ["_PAAS_PATCH_VAL"]
lines = f.read_text(encoding="utf-8").splitlines() if f.exists() else []
out, seen = [], False
for line in lines:
    if line.startswith(key + "="):
        out.append(f"{key}={val}")
        seen = True
    else:
        out.append(line)
if not seen:
    out.append(f"{key}={val}")
f.write_text("\n".join(out) + ("\n" if out else ""), encoding="utf-8")
PY
}

wait_sonar_up() {
  local n=0 body
  until body="$(curl -sS -m 15 "${SONAR_URL}/api/system/status" 2>/dev/null || true)" \
    && echo "${body}" | grep -q '"status":"UP"'; do
    n=$((n + 1))
    [[ "${n}" -le 60 ]] || fail "SonarQube not UP at ${SONAR_URL} (last: ${body:-connection failed})"
    echo "  waiting Sonar UP (${n}/60)…"
    sleep 10
  done
  ok "SonarQube UP at ${SONAR_URL}"
}

sonar_validate_creds() {
  local user="$1" pass="$2"
  curl -fsS -m 15 -u "${user}:${pass}" "${SONAR_URL}/api/authentication/validate" 2>/dev/null \
    | grep -q '"valid":true'
}

sonar_change_password() {
  local user="$1" old="$2" new="$3" http
  http="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -u "${user}:${old}" -X POST \
    "${SONAR_URL}/api/users/change_password?login=${user}&previousPassword=${old}&password=${new}" 2>/dev/null || echo 000)"
  [[ "${http}" == "204" || "${http}" == "200" ]]
}

ensure_admin_password() {
  if sonar_validate_creds "${SONAR_ADMIN_USER}" "${SONAR_ADMIN_NEW_PASSWORD}"; then
    ok "admin already uses configured new password (no UI change needed)"
    SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_NEW_PASSWORD}"
    return 0
  fi
  if sonar_change_password "${SONAR_ADMIN_USER}" "admin" "${SONAR_ADMIN_NEW_PASSWORD}"; then
    ok "admin password changed admin → ${SONAR_ADMIN_NEW_PASSWORD}"
    SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_NEW_PASSWORD}"
    return 0
  fi
  if [[ "${SONAR_ADMIN_PASSWORD}" != "admin" ]] \
      && sonar_change_password "${SONAR_ADMIN_USER}" "${SONAR_ADMIN_PASSWORD}" "${SONAR_ADMIN_NEW_PASSWORD}"; then
    ok "admin password changed (from SONAR_ADMIN_PASSWORD) → ${SONAR_ADMIN_NEW_PASSWORD}"
    SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_NEW_PASSWORD}"
    return 0
  fi
  fail "could not change admin password — try:
  SONAR_ADMIN_PASSWORD='password-you-used-in-UI' SONAR_ADMIN_NEW_PASSWORD='SonarQube123!' bash paas/scripts/lab.sh sonar-bootstrap
  Or manual:
  curl -u admin:admin -X POST '${SONAR_URL}/api/users/change_password?login=admin&previousPassword=admin&password=SonarQube123!'"
}

revoke_old_token() {
  local name="$1"
  local enc
  enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "${name}")"
  curl -fsS -m 15 -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASSWORD}" -X POST \
    "${SONAR_URL}/api/user_tokens/revoke?name=${enc}" >/dev/null 2>&1 || true
}

read_env_sonar_token() {
  grep -E '^SONAR_TOKEN=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true
}

sonar_token_valid() {
  local token="$1"
  [[ -n "${token}" ]] || return 1
  curl -fsS -m 15 -u "${token}:" "${SONAR_URL}/api/authentication/validate" 2>/dev/null \
    | grep -q '"valid":true'
}

create_analysis_token() {
  local resp token http existing
  existing="$(read_env_sonar_token)"
  if sonar_token_valid "${existing}"; then
    ok "existing SONAR_TOKEN still valid — reusing"
    printf '%s' "${existing}"
    return 0
  fi
  revoke_old_token "${SONAR_TOKEN_NAME}"
  resp="$(curl -sS -m 30 -w $'\n__HTTP__%{http_code}' -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASSWORD}" -X POST \
    "${SONAR_URL}/api/user_tokens/generate?name=${SONAR_TOKEN_NAME}&type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null)" \
    || true
  http="${resp##*$'\n__HTTP__'}"
  resp="${resp%$'\n__HTTP__'*}"
  if [[ "${http}" == "200" ]]; then
    token="$(printf '%s' "${resp}" | grep -o '"token":"[^"]*"' | head -1 | sed 's/.*"token":"//;s/"$//')"
    [[ -n "${token}" ]] || fail "empty token from Sonar: ${resp}"
    printf '%s' "${token}"
    return 0
  fi
  if [[ "${resp}" == *"already exists"* ]]; then
    warn "token name ${SONAR_TOKEN_NAME} already exists — revoke via UI or run:"
    echo "  curl -u admin:SonarQube123! -X POST '${SONAR_URL}/api/user_tokens/revoke?name=${SONAR_TOKEN_NAME}'"
    echo "  then re-run: bash paas/scripts/lab.sh sonar-bootstrap"
    fail "token generation HTTP ${http}: ${resp}"
  fi
  fail "token generation HTTP ${http}: ${resp}"
}

sync_env_and_jenkins() {
  local token="$1"
  for f in "${ENV_FILE}" "${DOT_ENV}"; do
    patch_env_key "${f}" "SONAR_BASE_URL" "${SONAR_URL}"
    patch_env_key "${f}" "SONAR_HOST_URL" "${SONAR_URL}"
    patch_env_key "${f}" "SONAR_TOKEN" "${token}"
    patch_env_key "${f}" "SONAR_ADMIN_USER" "${SONAR_ADMIN_USER}"
    patch_env_key "${f}" "SONAR_ADMIN_NEW_PASSWORD" "${SONAR_ADMIN_NEW_PASSWORD}"
    patch_env_key "${f}" "SONAR_TOKEN_NAME" "${SONAR_TOKEN_NAME}"
    ok "updated ${f}"
  done
  if [[ "${SYNC_JENKINS}" == "true" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
    python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force
    ok "Jenkins job parameters synced"
  fi
}

main() {
  need_cmd curl
  need_cmd python3

  echo "=============================================="
  echo " bootstrap-sonarqube-lab (CLI — bypass UI loop)"
  echo "=============================================="

  wait_sonar_up
  ensure_admin_password

  local token verify
  token="$(create_analysis_token)"
  ok "analysis token created (${#token} chars, starts with ${token:0:4}...)"

  verify="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -u "${token}:" \
    "${SONAR_URL}/api/authentication/validate" 2>/dev/null || echo 000)"
  [[ "${verify}" == "200" ]] || fail "token validate HTTP ${verify}"

  sync_env_and_jenkins "${token}"

  if [[ "${PAAS_SYNC_K8S_ENV:-true}" == "true" ]] && command -v kubectl >/dev/null 2>&1; then
    if kubectl get deployment frontend -n "${PAAS_NS:-paas}" >/dev/null 2>&1; then
      echo "==> Sync paas-frontend-env secret (SONAR_TOKEN)"
      PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-1}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" \
        || warn "k8s env sync failed — run: bash paas/scripts/lab.sh env"
    fi
  fi

  echo "=============================================="
  echo "Done."
  echo "  Sonar UI:  ${SONAR_URL}"
  echo "  Login:     ${SONAR_ADMIN_USER} / ${SONAR_ADMIN_PASSWORD}"
  echo "  Clear browser cookies for ${NODE_IP} if UI still loops, then login again."
  echo "  Next:      bash paas/scripts/lab.sh env"
  echo "             Trigger NEW Jenkins build (not Replay)"
  echo "=============================================="
}

main "$@"
