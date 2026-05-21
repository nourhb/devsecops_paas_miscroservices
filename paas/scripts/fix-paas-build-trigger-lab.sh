#!/usr/bin/env bash
# Fix PaaS "Tekton PipelineRun creation failed: HTTP request failed" on trigger build.
# Lab uses Jenkins (paas-deploy), not Tekton.
#
# Usage (k3s master):
#   bash paas/scripts/fix-paas-build-trigger-lab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY="${DEPLOY_NAME:-frontend}"
JENKINS_IN_CLUSTER="${JENKINS_IN_CLUSTER:-http://jenkins-service.cicd.svc.cluster.local:8080}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: ${ENV_FILE} not found. Copy from paas/frontend/docker-compose.env.k8s.example" >&2
  exit 1
fi

backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "${ENV_FILE}" "${backup}"
echo "==> Backup: ${backup}"

set_env_key() {
  local key="$1"
  local value="$2"
  if grep -q "^${key}=" "${ENV_FILE}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${ENV_FILE}"
  else
    echo "${key}=${value}" >> "${ENV_FILE}"
  fi
}

echo "==> BUILD_BACKEND=jenkins (was tekton → Tekton API/RBAC not available on lab)"
set_env_key BUILD_BACKEND jenkins

echo "==> Jenkins in-cluster URL (cicd namespace)"
set_env_key JENKINS_BASE_URL "${JENKINS_IN_CLUSTER}"
set_env_key JENKINS_URL "${JENKINS_IN_CLUSTER}"

if ! grep -q '^JENKINS_BUILD_JOB_NAME=' "${ENV_FILE}"; then
  set_env_key JENKINS_BUILD_JOB_NAME paas-deploy
fi
if ! grep -q '^JENKINS_DEPLOY_JOB_NAME=' "${ENV_FILE}"; then
  set_env_key JENKINS_DEPLOY_JOB_NAME paas-deploy
fi

echo "==> Sync env → frontend pod"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo ""
echo "==> Verify in pod"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY}" -- sh -c '
  echo BUILD_BACKEND=$BUILD_BACKEND
  echo JENKINS_BASE_URL=$JENKINS_BASE_URL
  echo JENKINS_BUILD_JOB_NAME=${JENKINS_BUILD_JOB_NAME:-<unset>}
' 2>/dev/null || true

echo ""
echo "==> Jenkins reachable from PaaS pod?"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY}" -- sh -c \
  'test -n "$JENKINS_BASE_URL" && wget -qO- --timeout=8 "$JENKINS_BASE_URL/api/json" 2>/dev/null | head -c 60 || echo FAIL'" 2>/dev/null || \
  echo "WARN: probe failed — set JENKINS_USERNAME and JENKINS_API_TOKEN in ${ENV_FILE}"

echo ""
echo "OK — refresh PaaS UI and trigger build again (should use Jenkins paas-deploy)."
