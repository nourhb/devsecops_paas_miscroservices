#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"

upsert_env() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

discover_sonar_url() {
  if command -v kubectl >/dev/null 2>&1; then
    for svc in sonarqube-sonarqube sonarqube; do
      local np
      np="$(kubectl get svc -n sonarqube "${svc}" -o jsonpath='{.spec.ports[?(@.port==9000)].nodePort}' 2>/dev/null || true)"
      [[ -n "${np}" && "${np}" != "null" ]] && echo "http://${NODE_IP}:${np}" && return 0
    done
  fi
  grep '^SONAR_BASE_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true
}

SONAR_BASE="$(discover_sonar_url)"
SONAR_USER="${SONAR_ADMIN_USER:-admin}"
SONAR_PASS="${SONAR_ADMIN_PASSWORD:-admin}"

echo "SonarQube: ${SONAR_BASE:-<not found>}"
if [[ -z "${SONAR_BASE}" ]]; then
  echo "ERROR: set SONAR_BASE_URL or install Sonar in namespace sonarqube" >&2
  exit 1
fi

upsert_env SONAR_BASE_URL "${SONAR_BASE}"
upsert_env SONAR_HOST_URL "${SONAR_BASE}"

echo "==> Sonar status"
if ! curl -fsS "${SONAR_BASE}/api/system/status" | head -c 200; then
  echo ""
  echo "FAIL: cannot reach ${SONAR_BASE} (connection refused / down)" >&2
  echo "Run: bash paas/scripts/recover-sonarqube-lab.sh" >&2
  echo "Or: bash paas/scripts/check.sh   # ensures sonarqube namespace" >&2
  exit 1
fi
echo ""

TOKEN_NAME="paas-lab-$(date +%s)"
RAW="$(curl -fsS -u "${SONAR_USER}:${SONAR_PASS}" -X POST \
  "${SONAR_BASE%/}/api/user_tokens/generate?name=${TOKEN_NAME}" 2>/dev/null || true)"
NEW_TOKEN="$(printf '%s' "${RAW}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"

if [[ -z "${NEW_TOKEN}" ]]; then
  echo "FAIL: could not generate token (wrong admin password or Sonar still starting)."
  echo "  Open ${SONAR_BASE} → log in → My Account → Security → Generate Token"
  exit 1
fi

upsert_env SONAR_TOKEN "${NEW_TOKEN}"
echo "OK: SONAR_TOKEN updated in ${ENV_FILE}"

echo "==> Validate"
curl -fsS -u "${NEW_TOKEN}:" "${SONAR_BASE%/}/api/authentication/validate"
echo ""

ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
kubectl rollout status deployment/frontend -n paas --timeout=300s

echo "==> Push SONAR_TOKEN into Jenkins paas-deploy job defaults"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full || true

echo "Done. Trigger a NEW deploy (not Rebuild) so Step 5 uses the new token."
