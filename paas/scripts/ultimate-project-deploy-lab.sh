#!/usr/bin/env bash
# One-shot lab deploy: Kyverno HTTP Harbor + GitOps chart + cluster rollout (uses GITOPS_REPO_TOKEN for push).
set -euo pipefail
PROJECT_NAME="${1:?usage: ultimate-project-deploy-lab.sh <project-slug> <jenkins-build> [port]}"
TAG="${2:?usage: ultimate-project-deploy-lab.sh <project-slug> <jenkins-build> [port]}"
TARGET_PORT="${3:-3000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
NS="${PROJECT_NAME}"
APP="paas-${PROJECT_NAME}"
URL="http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"

echo "=============================================="
echo " Ultimate deploy: ${PROJECT_NAME} :${TAG} :${TARGET_PORT}"
echo " URL: ${URL}"
echo "=============================================="

bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || true
bash "${SCRIPT_DIR}/lab.sh" fix-gitops
bash "${SCRIPT_DIR}/repair-gitops-app-lab.sh" "${PROJECT_NAME}" "${TAG}"
bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh"
bash "${SCRIPT_DIR}/ensure-harbor-nipio-cosign-lab.sh" "${PROJECT_NAME}" "${TAG}" || true
bash "${SCRIPT_DIR}/heal-project-deploy-lab.sh" "${PROJECT_NAME}" "${TAG}" "${TARGET_PORT}"

echo ""
echo "=============================================="
HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo '?')"
echo "HTTP ${URL} => ${HTTP}"
kubectl get application "${APP}" -n argocd 2>/dev/null || true
kubectl get deploy,pods -n "${NS}" 2>/dev/null || true
if [[ "${HTTP}" =~ ^[23] ]]; then
  echo "OK — app is up"
else
  echo "Diagnostics:"
  echo "  kubectl describe application ${APP} -n argocd | tail -25"
  echo "  kubectl get events -n ${NS} --sort-by=.lastTimestamp | tail -15"
fi
echo "=============================================="
