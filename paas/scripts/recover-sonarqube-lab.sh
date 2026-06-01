#!/usr/bin/env bash
# Restart SonarQube on lab k3s and refresh SONAR_BASE_URL / NodePort in docker-compose.env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
NS="sonarqube"

upsert_env() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || touch "${ENV_FILE}"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

echo "==> Sonar namespace / pods"
kubectl get ns "${NS}" >/dev/null 2>&1 || { echo "ERROR: namespace ${NS} missing — run: bash paas/scripts/check.sh" >&2; exit 1; }
kubectl get pods -n "${NS}" -o wide 2>/dev/null || true

echo "==> Scale up (lab VMs sometimes scale Sonar to 0)"
kubectl scale statefulset/sonarqube-sonarqube -n "${NS}" --replicas=1 2>/dev/null \
  || kubectl scale deployment -n "${NS}" --replicas=1 --all 2>/dev/null \
  || true

echo "==> Wait for pod Ready (up to 15 min on cold start)"
kubectl wait --for=condition=ready pod -n "${NS}" -l app=sonarqube --timeout=900s 2>/dev/null \
  || kubectl wait --for=condition=ready pod -n "${NS}" --timeout=900s 2>/dev/null \
  || echo "WARN: wait timed out — check: kubectl get pods -n ${NS}"

SONAR_URL=""
for svc in sonarqube-sonarqube sonarqube; do
  np="$(kubectl get svc -n "${NS}" "${svc}" -o jsonpath='{.spec.ports[?(@.port==9000)].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    SONAR_URL="http://${NODE_IP}:${np}"
    break
  fi
done

[[ -n "${SONAR_URL}" ]] || { echo "ERROR: no Sonar NodePort on 9000 in ${NS}" >&2; kubectl get svc -n "${NS}"; exit 1; }

echo "==> Probe ${SONAR_URL}"
for i in $(seq 1 60); do
  if curl -fsS "${SONAR_URL}/api/system/status" >/dev/null 2>&1; then
    echo "OK: Sonar UP"
    curl -fsS "${SONAR_URL}/api/system/status" | head -c 200
    echo ""
    upsert_env SONAR_BASE_URL "${SONAR_URL}"
    upsert_env SONAR_HOST_URL "${SONAR_URL}"
    echo "Updated ${ENV_FILE} with ${SONAR_URL}"
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
    echo ""
    echo "Next: bash paas/scripts/regenerate-sonar-token-lab.sh"
    exit 0
  fi
  echo "  waiting (${i}/60)…"
  sleep 10
done

echo "FAIL: Sonar not reachable at ${SONAR_URL}" >&2
kubectl logs -n "${NS}" -l app=sonarqube --tail=40 2>/dev/null || true
exit 1
