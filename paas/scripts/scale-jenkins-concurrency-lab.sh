#!/usr/bin/env bash
# Enable parallel paas-deploy builds: more Jenkins executors + concurrent job + PaaS deploy cap.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
EXECUTORS="${JENKINS_NUM_EXECUTORS:-8}"

upsert() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" 2>/dev/null || \
      sed -i '' "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

cd "${REPO_ROOT}"
git pull origin main 2>/dev/null || true

echo "==> Parallel deploys: ${EXECUTORS} Jenkins executors + concurrent paas-deploy"
upsert JENKINS_NUM_EXECUTORS "${EXECUTORS}"
upsert JENKINS_PAAS_CONCURRENT_BUILDS "true"
upsert PAAS_MAX_CONCURRENT_JENKINS_DEPLOYS "${EXECUTORS}"

echo "==> Sync Jenkinsfile ConfigMap"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh"

echo "==> Jenkins: ${EXECUTORS} executors, concurrent builds, refresh job XML"
export JENKINS_NUM_EXECUTORS="${EXECUTORS}"
export JENKINS_PAAS_CONCURRENT_BUILDS=true
python3 "${SCRIPT_DIR}/jenkins-configure-lab.py"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

if [[ "${SCALE_JENKINS_SKIP_FRONTEND:-}" != "1" ]]; then
  echo "==> Redeploy PaaS frontend (new concurrency env)"
  bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"
else
  echo "==> Skip frontend deploy (caller will redeploy)"
fi

echo ""
echo "OK. You can deploy ${EXECUTORS} projects at once from the PaaS UI."
echo "  kubectl exec -n cicd deploy/jenkins -- curl -fsS http://127.0.0.1:8080/computer/api/json?tree=numExecutors 2>/dev/null | head -c 200 || true"
echo "  For more than ${EXECUTORS}: JENKINS_NUM_EXECUTORS=12 bash paas/scripts/scale-jenkins-concurrency-lab.sh"
