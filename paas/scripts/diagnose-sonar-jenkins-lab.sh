#!/usr/bin/env bash
# Test Sonar reachability + token from the Jenkins agent pod (same network as Step 5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a

JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_LAB_LOOPBACK:-${JENKINS_BASE_URL:-http://127.0.0.1:30090}}}"
JENKINS_URL="${JENKINS_URL%/}"
JOB="${JENKINS_BUILD_JOB_NAME:-paas-deploy}"

find_jenkins_pod() {
  local ns pod
  if [[ -n "${JENKINS_POD:-}" && -n "${JENKINS_NS:-}" ]]; then
    echo "${JENKINS_NS} ${JENKINS_POD}"
    return 0
  fi
  for ns in cicd jenkins paas; do
    for sel in 'app=jenkins' 'app.kubernetes.io/component=jenkins-controller' 'app.kubernetes.io/name=jenkins'; do
      pod="$(kubectl get pod -n "${ns}" -l "${sel}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [[ -n "${pod}" ]]; then
        echo "${ns} ${pod}"
        return 0
      fi
    done
  done
  pod="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | awk '/jenkins/ && $2 !~ /debug|Completed/ {print; exit}' || true)"
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi
  return 1
}

JENKINS_LOC="$(find_jenkins_pod || true)"
if [[ -z "${JENKINS_LOC}" ]]; then
  echo "ERROR: no Jenkins pod (tried cicd/jenkins/paas; kubectl get pods -A | grep -i jenkins)" >&2
  echo "  If API is up but kubectl times out: bash paas/scripts/recover-k3s-api-lab.sh" >&2
  echo "  Or set: JENKINS_NS=cicd JENKINS_POD=<pod> $0" >&2
  exit 1
fi
NS="${JENKINS_LOC%% *}"
POD="${JENKINS_LOC#* }"

echo "==> Jenkins API ${JENKINS_URL}"
if ! curl -fsS -m 8 "${JENKINS_URL}/login" >/dev/null 2>&1; then
  echo "WARN: Jenkins not reachable at ${JENKINS_URL} (127.0.0.1:30090 often refused — use JENKINS_PROBE_URL / NodePort IP)"
  echo "  Try: export JENKINS_PROBE_URL=http://192.168.56.129:30090"
fi

echo "==> Jenkins pod: ${NS}/${POD}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
for URL in \
  "http://sonarqube-sonarqube.sonarqube.svc.cluster.local:9000" \
  "http://sonarqube-service.sonarqube.svc.cluster.local:9000" \
  "${SONAR_BASE_URL:-}" \
  "${SONAR_HOST_URL:-}"; do
  [[ -z "${URL}" ]] && continue
  echo "--- probe ${URL} (from Jenkins pod)"
  kubectl exec -n "${NS}" "${POD}" -c "${JENKINS_CONTAINER}" -- sh -c "
    if command -v curl >/dev/null 2>&1; then
      curl -sS -m 10 -u '${SONAR_TOKEN}:' '${URL%/}/api/authentication/validate' || echo FAIL
      curl -sS -m 10 '${URL%/}/api/system/status' | head -c 120 || echo FAIL
    elif command -v wget >/dev/null 2>&1; then
      wget -qO- --timeout=10 --user='${SONAR_TOKEN}' --password='' '${URL%/}/api/authentication/validate' || echo FAIL
    else
      echo 'no curl/wget in Jenkins pod'
    fi
  " 2>/dev/null || echo "exec failed (pod not Ready? kubectl get pod -n ${NS} ${POD})"
done

echo ""
echo "Jenkins job SONAR_TOKEN vs env (length only):"
if [[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
  JOB_TOKEN_LEN="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/config.xml" 2>/dev/null \
    | python3 -c "
import re, sys
c = sys.stdin.read()
m = re.search(r'<name>SONAR_TOKEN</name>.*?<defaultValue>([^<]*)</defaultValue>', c, re.S)
print(len(m.group(1).strip()) if m else 0)
" 2>/dev/null || echo 0)"
  echo "  env SONAR_TOKEN length: ${#SONAR_TOKEN}"
  echo "  job default SONAR_TOKEN length: ${JOB_TOKEN_LEN}"
  if [[ "${JOB_TOKEN_LEN}" != "${#SONAR_TOKEN}" ]]; then
    echo "  WARN: mismatch — run: bash paas/scripts/regenerate-sonar-token-lab.sh"
  fi
fi

echo ""
echo "If NodePort fails but cluster URL works, sync Jenkinsfile and redeploy:"
echo "  bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "  bash paas/scripts/sync-paas-jenkinsfile-configmap-k8s.sh"

BUILD="${BUILD_NUMBER:-}"
if [[ -n "${BUILD}" && -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
  echo ""
  echo "==> Jenkins build #${BUILD} Sonar console excerpt"
  CONSOLE="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/${JOB}/${BUILD}/consoleText" 2>/dev/null || true)"
  if [[ -n "${CONSOLE}" ]]; then
    echo "${CONSOLE}" | awk '
      /\[sonar\] using / { show=1 }
      show { print }
      /PAAS_STEP_(OK|WARN) step=5/ { exit }
    ' | tail -80
    echo ""
    echo "==> Artifact paas-artifacts/sonar-scanner.log (if archived)"
    ART_URL="${JENKINS_URL}/job/${JOB}/${BUILD}/artifact/paas-artifacts/sonar-scanner.log"
    if curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${ART_URL}" 2>/dev/null | tail -40; then
      if curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${ART_URL}" 2>/dev/null | grep -qi 'Not authorized'; then
        echo ""
        echo "FIX: bash paas/scripts/regenerate-sonar-token-lab.sh"
        echo "     bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh   # needs sonar.login in Jenkinsfile"
      fi
    else
      echo "(artifact not found — build may predate sonar log path or archive step skipped)"
    fi
  else
    echo "WARN: could not fetch console for build #${BUILD}"
  fi
fi
