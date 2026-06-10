#!/usr/bin/env bash
# Rotate Dependency-Track API key (fixes HTTP 401 on /api/v1/project and Step 4 SBOM upload).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
DT_USER="${DT_ADMIN_USER:-admin}"
DT_PASS="${DT_ADMIN_PASSWORD:-admin}"

upsert_env() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

discover_dt_url() {
  if command -v kubectl >/dev/null 2>&1; then
    for svc in dtrack-dependency-track-api-server dependency-track-api-server api-server; do
      local np
      np="$(kubectl get svc -n dependency-track "${svc}" -o jsonpath='{.spec.ports[?(@.port==8080)].nodePort}' 2>/dev/null || true)"
      [[ -n "${np}" && "${np}" != "null" ]] && echo "http://${NODE_IP}:${np}" && return 0
    done
  fi
  grep '^DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true
}

DT_BASE="$(discover_dt_url)"
[[ -n "${DT_BASE}" ]] || { echo "ERROR: set DEPENDENCY_TRACK_BASE_URL or install Dependency-Track" >&2; exit 1; }
upsert_env DEPENDENCY_TRACK_BASE_URL "${DT_BASE}"

CUR_KEY="$(grep '^DEPENDENCY_TRACK_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
if [[ -n "${CUR_KEY}" ]]; then
  HTTP="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H "X-Api-Key: ${CUR_KEY}" "${DT_BASE%/}/api/v1/project" || true)"
  if [[ "${HTTP}" == "200" ]]; then
    echo "OK: existing DEPENDENCY_TRACK_API_KEY works (HTTP 200)"
    exit 0
  fi
  echo "WARN: current API key rejected (HTTP ${HTTP:-err}) — generating a new key"
fi

echo "Dependency-Track API: ${DT_BASE}"

dt_login() {
  local user="$1" pass="$2"
  curl -fsS -m 20 -X POST "${DT_BASE%/}/api/v1/user/login" \
    -d "username=${user}" -d "password=${pass}" 2>/dev/null || true
}

TOKEN="$(dt_login "${DT_USER}" "${DT_PASS}")"
if [[ -z "${TOKEN}" || "${TOKEN}" == *"Invalid"* ]]; then
  NEW_PASS="${DT_ADMIN_NEW_PASSWORD:-admin123}"
  echo "==> Try force password change (default admin/admin → ${NEW_PASS})"
  curl -fsS -m 20 -X POST "${DT_BASE%/}/api/v1/user/forceChangePassword" \
    -d "username=${DT_USER}" -d "password=${DT_PASS}" \
    -d "newPassword=${NEW_PASS}" -d "confirmPassword=${NEW_PASS}" >/dev/null 2>&1 || true
  DT_PASS="${NEW_PASS}"
  TOKEN="$(dt_login "${DT_USER}" "${DT_PASS}")"
fi

if [[ -z "${TOKEN}" || "${TOKEN}" == *"Invalid"* ]]; then
  echo "FAIL: could not log in to Dependency-Track as ${DT_USER}" >&2
  echo "  Open $(kubectl get svc -n dependency-track dtrack-dependency-track-frontend -o jsonpath='http://'"${NODE_IP}"':{.spec.ports[0].nodePort}' 2>/dev/null || echo dependency-track UI)" >&2
  echo "  Administration → Access Management → Teams → Administrators → API Keys → Generate" >&2
  echo "  Then set DEPENDENCY_TRACK_API_KEY=odt_... in ${ENV_FILE}" >&2
  exit 1
fi

TEAM_UUID="$(curl -fsS -m 20 -H "Authorization: Bearer ${TOKEN}" "${DT_BASE%/}/api/v1/team" \
  | python3 -c "
import json,sys
teams=json.load(sys.stdin)
for t in teams if isinstance(teams,list) else []:
    if (t.get('name') or '').lower() in ('administrators','administrator'):
        print(t.get('uuid',''))
        break
else:
    for t in teams if isinstance(teams,list) else []:
        if t.get('name'):
            print(t.get('uuid',''))
            break
" 2>/dev/null || true)"

if [[ -z "${TEAM_UUID}" ]]; then
  echo "FAIL: could not resolve Administrators team UUID" >&2
  exit 1
fi

KEY_JSON="$(curl -fsS -m 20 -X PUT -H "Authorization: Bearer ${TOKEN}" \
  "${DT_BASE%/}/api/v1/team/${TEAM_UUID}/key" 2>/dev/null || true)"
NEW_KEY="$(printf '%s' "${KEY_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('key',''))" 2>/dev/null || true)"

if [[ -z "${NEW_KEY}" ]]; then
  echo "FAIL: team key generation returned empty response" >&2
  echo "${KEY_JSON}" | head -c 400
  exit 1
fi

upsert_env DEPENDENCY_TRACK_API_KEY "${NEW_KEY}"
echo "OK: DEPENDENCY_TRACK_API_KEY updated in ${ENV_FILE}"

HTTP="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H "X-Api-Key: ${NEW_KEY}" "${DT_BASE%/}/api/v1/project" || true)"
[[ "${HTTP}" == "200" ]] || { echo "FAIL: new key still rejected (HTTP ${HTTP})" >&2; exit 1; }
echo "OK: /api/v1/project HTTP 200"

if [[ "${REGENERATE_DT_SKIP_DEPLOY:-}" != "1" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
  kubectl rollout status deployment/frontend -n paas --timeout=300s
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set +a
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full || true
fi

echo ""
echo "Done. Re-run Step 4 for sanhome (new Jenkins build — SBOM upload uses the new key):"
echo "  export PROJECT_ID=\$(bash paas/scripts/get-project-id-lab.sh sanhome)"
echo "  PROJECT_ID=\$PROJECT_ID python3 paas/scripts/trigger-paas-deploy-lab.py"
