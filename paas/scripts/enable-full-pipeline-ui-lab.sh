#!/usr/bin/env bash
# One-shot: full security pipeline + build env + frontend for UI-only users.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

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

echo "==> Full pipeline (no fast skip)"
upsert JENKINS_PAAS_FAST_PIPELINE "false"
upsert PAAS_ALLOW_FAST_PIPELINE "false"

echo "==> Sync Jenkinsfile + redeploy PaaS frontend (build env + security triggers)"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh"
bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"

echo ""
echo "OK. From PaaS UI only:"
echo "  1. Edit project → Application environment (.env) → Save"
echo "  2. Deploy (full pipeline: Steps 4–5 Sonar/SCA run; results on Security + Pipeline pages)"
echo ""
echo "Check pod env:"
echo "  kubectl exec -n paas deploy/frontend -- printenv JENKINS_PAAS_FAST_PIPELINE PAAS_ALLOW_FAST_PIPELINE | head"
