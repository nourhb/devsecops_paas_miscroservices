#!/usr/bin/env bash
# Ensure SonarQube NodePort responds before paas-deploy Step 5.
set -euo pipefail
NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"

sonar_status_up() {
  curl -fsS -m 12 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'
}

restart_sonar_workload() {
  local dep
  dep="$(kubectl get deploy -n "${SONAR_NS}" --request-timeout=20s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${dep}" ]]; then
    echo "==> rollout restart deploy/${dep} -n ${SONAR_NS}"
    kubectl rollout restart "deploy/${dep}" -n "${SONAR_NS}" --request-timeout=60s
    kubectl rollout status "deploy/${dep}" -n "${SONAR_NS}" --timeout=600s --request-timeout=60s || true
    return 0
  fi
  echo "==> delete non-Running Sonar pods in ${SONAR_NS}"
  kubectl delete pod -n "${SONAR_NS}" --field-selector=status.phase!=Running --request-timeout=60s 2>/dev/null || true
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s -o name 2>/dev/null \
    | while read -r pod; do
        kubectl delete "${pod}" -n "${SONAR_NS}" --request-timeout=60s 2>/dev/null || true
      done
}

wait_sonar_up() {
  local i
  for i in $(seq 1 36); do
    if sonar_status_up; then
      echo "OK: SonarQube UP at ${SONAR_URL} (after ${i} probe(s))"
      return 0
    fi
    echo "  waiting Sonar UP (${i}/36)…"
    sleep 10
  done
  return 1
}

main() {
  echo "==> SonarQube recover (${SONAR_URL})"
  if sonar_status_up; then
    echo "OK: SonarQube already UP"
    exit 0
  fi
  echo "WARN: SonarQube not UP — restarting workload"
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s 2>/dev/null || true
  restart_sonar_workload || true
  if wait_sonar_up; then
    exit 0
  fi
  echo "FAIL: SonarQube still down at ${SONAR_URL}" >&2
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s 2>/dev/null || true
  exit 1
}

main "$@"
