#!/usr/bin/env bash
# Heal SonarQube for Jenkins Step 5 — status UP is not enough; rules API must return 200.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_PASSWORD:-}"

read_env_key() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] || return 1
  grep -m1 "^${key}=" "${file}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

load_sonar_creds() {
  if [[ -z "${SONAR_TOKEN}" ]]; then
    SONAR_TOKEN="$(read_env_key SONAR_TOKEN "${ENV_FILE}" || true)"
    [[ -n "${SONAR_TOKEN}" ]] || SONAR_TOKEN="$(read_env_key SONAR_TOKEN "${REPO_ROOT}/paas/frontend/.env" || true)"
  fi
  if [[ -z "${SONAR_ADMIN_PASSWORD}" ]]; then
    SONAR_ADMIN_PASSWORD="$(read_env_key SONAR_ADMIN_PASSWORD "${ENV_FILE}" || true)"
  fi
  SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_PASSWORD:-SonarQube123!}"
}

sonar_curl_user() {
  local user="$1" pass="$2" timeout="$3"
  shift 3
  curl -sS -m "${timeout}" -u "${user}:${pass}" "$@"
}

sonar_curl_auth() {
  local timeout="$1"
  shift
  if [[ -n "${SONAR_TOKEN}" ]]; then
    curl -sS -m "${timeout}" -u "${SONAR_TOKEN}:" "$@"
    return
  fi
  sonar_curl_user "${SONAR_ADMIN_USER}" "${SONAR_ADMIN_PASSWORD}" "${timeout}" "$@"
}

sonar_status_up() {
  curl -fsS -m 15 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'
}

sonar_rules_http_with() {
  local auth_mode="$1"
  local http pass
  if [[ "${auth_mode}" == token && -n "${SONAR_TOKEN}" ]]; then
    http="$(curl -sS -o /dev/null -w '%{http_code}' -m 45 -u "${SONAR_TOKEN}:" \
      "${SONAR_URL}/api/rules/search?activation=true&ps=1" 2>/dev/null || echo 000)"
    echo "${http}"
    return
  fi
  for pass in "${SONAR_ADMIN_PASSWORD}" SonarQube123! admin; do
    http="$(sonar_curl_user "${SONAR_ADMIN_USER}" "${pass}" 45 -o /dev/null -w '%{http_code}' \
      "${SONAR_URL}/api/rules/search?activation=true&ps=1" 2>/dev/null || echo 000)"
    if [[ "${http}" == "200" ]]; then
      SONAR_ADMIN_PASSWORD="${pass}"
      echo 200
      return
    fi
  done
  echo "${http}"
}

sonar_rules_http() {
  local http
  http="$(sonar_rules_http_with token)"
  [[ "${http}" == "200" ]] && { echo 200; return; }
  sonar_rules_http_with admin
}

sonar_rules_ok() {
  [[ "$(sonar_rules_http)" == "200" ]]
}

token_valid() {
  [[ -n "${SONAR_TOKEN}" ]] || return 1
  curl -fsS -m 15 -u "${SONAR_TOKEN}:" "${SONAR_URL}/api/authentication/validate" 2>/dev/null \
    | grep -q '"valid":true'
}

cancel_ce_tasks() {
  echo "==> Cancel pending Sonar compute-engine tasks (stuck analyses)"
  sonar_curl_auth 20 -X POST "${SONAR_URL}/api/ce/cancel_all" >/dev/null 2>&1 || true
}

restart_sonar_workload() {
  local dep sts
  cancel_ce_tasks
  dep="$(kubectl get deploy -n "${SONAR_NS}" --request-timeout=20s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${dep}" ]]; then
    echo "==> rollout restart deploy/${dep} -n ${SONAR_NS}"
    kubectl rollout restart "deploy/${dep}" -n "${SONAR_NS}" --request-timeout=60s
    kubectl rollout status "deploy/${dep}" -n "${SONAR_NS}" --timeout=900s --request-timeout=60s || true
  fi
  sts="$(kubectl get sts -n "${SONAR_NS}" --request-timeout=20s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${sts}" ]]; then
    echo "==> rollout restart statefulset/${sts} -n ${SONAR_NS}"
    kubectl rollout restart "statefulset/${sts}" -n "${SONAR_NS}" --request-timeout=60s
    kubectl rollout status "statefulset/${sts}" -n "${SONAR_NS}" --timeout=900s --request-timeout=60s || true
  fi
  if [[ -z "${dep}" && -z "${sts}" ]]; then
    kubectl delete pod -n "${SONAR_NS}" --field-selector=status.phase!=Running --request-timeout=60s 2>/dev/null || true
  fi
}

wait_sonar_ready() {
  local i rules_http
  for i in $(seq 1 48); do
    if sonar_status_up && sonar_rules_ok; then
      echo "OK: SonarQube ready at ${SONAR_URL} (status UP + rules API 200, ${i} probe(s))"
      return 0
    fi
    rules_http="$(sonar_rules_http)"
    if sonar_status_up; then
      echo "  [${i}/48] status UP but rules API HTTP ${rules_http} — waiting…"
    else
      echo "  [${i}/48] Sonar not UP yet…"
    fi
    sleep 10
  done
  return 1
}

regen_token_if_needed() {
  local rules_http
  rules_http="$(sonar_rules_http)"
  if [[ "${rules_http}" == "200" ]] && token_valid; then
    return 0
  fi
  if [[ "${rules_http}" == "200" ]] && ! token_valid; then
    echo "WARN: Sonar UP but SONAR_TOKEN invalid — regenerating via sonar-bootstrap"
    bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh"
    load_sonar_creds
    return 0
  fi
  if [[ "${rules_http}" == "401" ]]; then
    echo "WARN: rules API 401 — Sonar may have reset (no PVC). Running sonar-bootstrap…"
    bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh"
    load_sonar_creds
  fi
}

main() {
  load_sonar_creds
  echo "=============================================="
  echo " lab-sonarqube-recover — ${SONAR_URL}"
  echo "=============================================="
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s 2>/dev/null || true

  if sonar_status_up && sonar_rules_ok && { [[ -z "${SONAR_TOKEN}" ]] || token_valid; }; then
    echo "OK: SonarQube healthy (rules API 200, token valid)"
    exit 0
  fi

  if sonar_status_up && sonar_rules_ok && ! token_valid; then
    regen_token_if_needed
    if token_valid; then
      echo "OK: SonarQube healthy after token regen"
      echo "  Run: bash paas/scripts/lab.sh env"
      exit 0
    fi
  fi

  if sonar_status_up; then
    echo "WARN: Sonar reports UP but rules API HTTP $(sonar_rules_http) — restarting workload"
    echo "      Cancel other paas-deploy builds first."
  else
    echo "WARN: SonarQube not UP — restarting workload"
  fi

  restart_sonar_workload || true

  if wait_sonar_ready; then
    regen_token_if_needed
    echo ""
    echo "Run: bash paas/scripts/lab.sh env"
    echo "Then ONE Jenkins deploy at a time."
    exit 0
  fi

  rules_http="$(sonar_rules_http)"
  if [[ "${rules_http}" == "401" ]]; then
    echo "==> Attempting sonar-bootstrap (admin password + new token)…"
    if bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh"; then
      echo "OK: sonar-bootstrap done — run: bash paas/scripts/lab.sh env"
      exit 0
    fi
  fi

  echo "FAIL: SonarQube still unhealthy at ${SONAR_URL}" >&2
  echo "  rules API HTTP: ${rules_http}" >&2
  echo "  token valid: $(token_valid && echo yes || echo no)" >&2
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s 2>/dev/null || true
  exit 1
}

main "$@"
