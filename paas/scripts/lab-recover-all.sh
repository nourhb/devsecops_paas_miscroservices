#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/lab-common.sh"
REPO_ROOT="$(lab_repo_root)"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
ENV_FILE="${REPO_ROOT}/paas/frontend/docker-compose.env"
source "${SCRIPT_DIR}/lib/harbor-manifest-check.sh"

echo "harbor registry"
kubectl wait --for=condition=ready pod -l app=harbor,component=registry -n harbor --timeout=120s
V2="$(curl -sS -o /dev/null -w '%{http_code}' -I "http://${HARBOR}/v2/")"
[[ "$V2" == "401" || "$V2" == "200" ]] || exit 1

if [[ "${PURGE_HARBOR_REPOS:-}" == "1" ]]; then
  for repo in paas/simple-app paas/paas-frontend; do
    curl -sS -o /dev/null -w "DELETE ${repo} %{http_code}\n" -X DELETE -u "${HARBOR_USER}:${HARBOR_PASS}" \
      "http://${HARBOR}/api/v2.0/projects/paas/repositories/$(basename "$repo")" 2>/dev/null || true
  done
  sleep 3
fi

bash "${REPO_ROOT}/paas/scripts/fix-paas-frontend-pull-lab.sh"
FE_MAN="$(harbor_manifest_http_code "${HARBOR}" paas/paas-frontend latest "${HARBOR_USER}" "${HARBOR_PASS}")"
echo "paas-frontend:latest manifest HTTP ${FE_MAN}"

HTTP_PAAS="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30100/" 2>/dev/null || echo 000)"
echo "PaaS UI HTTP ${HTTP_PAAS}"

lab_jenkins_trigger_paas_deploy "${ENV_FILE}"
echo "after Jenkins SUCCESS:"
echo "  export GITHUB_TOKEN=ghp_..."
echo "  bash paas/scripts/final-deploy-simple-app-lab.sh <build_number>"
