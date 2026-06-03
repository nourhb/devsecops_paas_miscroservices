#!/usr/bin/env bash
# Jenkins (in-cluster) → push crane layers via harbor-registry Service (bypasses nginx NodePort 502).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

upsert() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "FAIL: missing ${ENV_FILE}" >&2; exit 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

echo "==> Wire HARBOR_REGISTRY_CLUSTER from kubectl"
bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}"

CLUSTER="$(grep '^HARBOR_REGISTRY_CLUSTER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
if [[ -z "${CLUSTER}" ]]; then
  echo "FAIL: HARBOR_REGISTRY_CLUSTER not set — is Harbor installed? kubectl get svc -n harbor" >&2
  exit 1
fi

upsert "HARBOR_REGISTRY_PUSH" "${CLUSTER}"
echo "OK: HARBOR_REGISTRY_PUSH=${CLUSTER} (crane append; IMAGE_NAME / GitOps still use HARBOR_REGISTRY NodePort)"

echo ""
echo "==> Recover Harbor (registry + nginx)"
bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || true

echo ""
echo "OK — next: bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "Then trigger a NEW paas-deploy build. Console should show:"
echo "  marker=harbor-registry-push-20260603"
echo "  [image] Harbor crane push via in-cluster registry ${CLUSTER}"
echo ""
echo "If push still fails: kubectl logs -n harbor deploy/harbor-registry --tail=80"
