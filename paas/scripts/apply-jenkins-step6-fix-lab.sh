#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
JENKINS_DEPLOY="${JENKINS_DEPLOY:-jenkins}"
JAVA_HEARTBEAT="-Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=86400"
MARKER='crane-next16-202605-j48300-split'

cd "${REPO_ROOT}"

echo "==> 1. Restore create_jenkins_paas_deploy_job.py if truncated"
PY="${REPO_ROOT}/paas/scripts/create_jenkins_paas_deploy_job.py"
if ! python3 -m py_compile "${PY}" 2>/dev/null; then
  echo "WARN: ${PY} broken — restoring from b2d56b8"
  git checkout b2d56b8 -- paas/scripts/create_jenkins_paas_deploy_job.py
  sed -i 's/crane-next16-202605"/crane-next16-202605-j48300-split"/' "${PY}" 2>/dev/null || \
    sed -i '' 's/crane-next16-202605"/crane-next16-202605-j48300-split"/' "${PY}" 2>/dev/null || true
fi
python3 -m py_compile "${PY}"

if ! grep -qF 'monorepo-app-root-20260531' "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"; then
  echo "ERROR: Jenkinsfile missing monorepo-app-root-20260531 (start-paas.sh mutate fix). git pull origin main." >&2
  exit 1
fi
if grep -qF '--cmd=-c' "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"; then
  echo "ERROR: Jenkinsfile still has broken crane mutate (--cmd=-c). git pull origin main." >&2
  exit 1
fi

echo "==> 2. JENKINS_PAAS_FAST_PIPELINE=false (Step 3 builds; Step 6 only packages)"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -qE '^JENKINS_PAAS_FAST_PIPELINE=true' "${ENV_FILE}"; then
    sed -i 's/^JENKINS_PAAS_FAST_PIPELINE=true/JENKINS_PAAS_FAST_PIPELINE=false/' "${ENV_FILE}" 2>/dev/null || \
      sed -i '' 's/^JENKINS_PAAS_FAST_PIPELINE=true/JENKINS_PAAS_FAST_PIPELINE=false/' "${ENV_FILE}"
    echo "Updated ${ENV_FILE}"
  else
    echo "OK: not set to true in ${ENV_FILE}"
  fi
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
else
  echo "WARN: ${ENV_FILE} missing — set JENKINS_PAAS_FAST_PIPELINE=false manually"
fi

echo "==> 3. Jenkins JAVA_OPTS (JENKINS-48300)"
if kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" >/dev/null 2>&1; then
  CUR="$(kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JAVA_OPTS")].value}' 2>/dev/null || true)"
  if [[ "${CUR}" != *HEARTBEAT_CHECK_INTERVAL* ]]; then
    NEW_OPTS="${CUR:--Xms256m -Xmx768m -Djenkins.install.runSetupWizard=false} ${JAVA_HEARTBEAT}"
    kubectl set env deployment/"${JENKINS_DEPLOY}" -n "${JENKINS_NS}" JAVA_OPTS="${NEW_OPTS}"
    kubectl rollout status deployment/"${JENKINS_DEPLOY}" -n "${JENKINS_NS}" --timeout=300s
    echo "Jenkins restarted — wait for it to be up before triggering builds"
  else
    echo "OK: JAVA_OPTS already patched"
  fi
else
  echo "WARN: no deployment/${JENKINS_DEPLOY} in ${JENKINS_NS}"
fi

echo "==> 4. Wait for Jenkins NodePort"
JENKINS_WAIT_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
for i in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 "${JENKINS_WAIT_URL}/api/json" >/dev/null 2>&1; then
    echo "OK: ${JENKINS_WAIT_URL}"
    break
  fi
  echo "waiting (${i}/60)…"
  sleep 5
  [[ "${i}" -eq 60 ]] && { echo "FAIL: Jenkins not ready"; exit 1; }
done

echo "==> 5. Push Jenkinsfile to paas-deploy job"
bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh"

echo "OK. Trigger a NEW build (not Rebuild). Step 6 console must show:"
echo "  marker monorepo-app-root-20260531"
echo "  [image] crane mutate OK"
echo "  (must NOT show: mutate runs as a separate pipeline sh step or --cmd=-c)"
