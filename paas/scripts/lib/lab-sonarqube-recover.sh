#!/usr/bin/env bash
# Heal SonarQube for Jenkins Step 5 — status UP is not enough; rules API must return 200.
set -euo pipefail
NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"
SONAR_TOKEN="${SONAR_TOKEN:-}"

sonar_curl_auth() {
  if [[ -n "${SONAR_TOKEN}" ]]; then
    curl -sS -m "$1" -u "${SONAR_TOKEN}:" "${@:2}"
  else
    curl -sS -m "$1" -u admin:SonarQube123! "${@:2}"
  fi
}

sonar_status_up() {
  curl -fsS -m 15 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'
}

sonar_rules_http() {
  sonar_curl_auth 45 -o /dev/null -w '%{http_code}' \
    "${SONAR_URL}/api/rules/search?activation=true&ps=1" 2>/dev/null || echo 000
}

sonar_rules_ok() {
  [[ "$(sonar_rules_http)" == "200" ]]
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
    kubectl rollout status "deploy/${dep}" -n "${SONAR_NS}" --timeout=600s --request-timeout=60s || true
  fi
  sts="$(kubectl get sts -n "${SONAR_NS}" --request-timeout=20s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${sts}" ]]; then
    echo "==> rollout restart statefulset/${sts} -n ${SONAR_NS}"
    kubectl rollout restart "statefulset/${sts}" -n "${SONAR_NS}" --request-timeout=60s
    kubectl rollout status "statefulset/${sts}" -n "${SONAR_NS}" --timeout=600s --request-timeout=60s || true
  fi
  if [[ -z "${dep}" && -z "${sts}" ]]; then
    echo "==> delete non-Running Sonar pods in ${SONAR_NS}"
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
      echo "  [${i}/48] status UP but rules API HTTP ${rules_http} — waiting for CE/ES…"
    else
      echo "  [${i}/48] Sonar not UP yet…"
    fi
    sleep 10
  done
  return 1
}

main() {
  echo "=============================================="
  echo " lab-sonarqube-recover — ${SONAR_URL}"
  echo "=============================================="
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s 2>/dev/null || true

  if sonar_status_up && sonar_rules_ok; then
    echo "OK: SonarQube healthy (rules API 200)"
    exit 0
  fi

  if sonar_status_up; then
    echo "WARN: Sonar reports UP but rules API HTTP $(sonar_rules_http) — typical after parallel Jenkins scans or OOM"
    echo "      Cancel other paas-deploy builds, then restarting Sonar…"
  else
    echo "WARN: SonarQube not UP — restarting workload"
  fi

  restart_sonar_workload || true

  if wait_sonar_ready; then
    echo ""
    echo "Run ONE Jenkins deploy at a time until Step 5 passes."
    exit 0
  fi

  echo "FAIL: SonarQube still unhealthy at ${SONAR_URL}" >&2
  echo "  rules API HTTP: $(sonar_rules_http)" >&2
  echo "  Check: kubectl logs -n ${SONAR_NS} -l app=sonarqube --tail=80" >&2
  echo "  Disk:  df -h /" >&2
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s 2>/dev/null || true
  exit 1
}

main "$@"
