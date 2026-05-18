#!/usr/bin/env bash
# Recover PaaS UI (namespace paas) + optional Jenkins trigger + final simple-app deploy.
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
PAAS_NS="${PAAS_NS:-paas}"
PROJECT_ID="${PROJECT_ID:-179dcf7f-ad21-4421-9114-0171f3e9914c}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "=== A. PaaS frontend (namespace ${PAAS_NS}) ==="
kubectl get deployment,rs,pods -n "${PAAS_NS}" 2>/dev/null || true

if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "WARN: deployment/frontend not found in ${PAAS_NS}. Check: kubectl get deploy -A | grep frontend"
else
  kubectl set image deployment/frontend -n "${PAAS_NS}" \
    frontend="${HARBOR}/paas/paas-frontend:latest" --record 2>/dev/null || \
    kubectl set image deployment/frontend -n "${PAAS_NS}" \
    "*=${HARBOR}/paas/paas-frontend:latest" 2>/dev/null || true

  if kubectl get secret harbor-regcred -n "${PAAS_NS}" >/dev/null 2>&1; then
    echo "harbor-regcred exists in ${PAAS_NS}"
  elif kubectl get secret harbor-regcred -n harbor >/dev/null 2>&1; then
    kubectl get secret harbor-regcred -n harbor -o yaml \
      | sed "s/namespace: harbor/namespace: ${PAAS_NS}/" \
      | kubectl apply -f -
  fi

  kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s || {
    echo "--- events ---"
    kubectl describe deployment frontend -n "${PAAS_NS}" | tail -30
    kubectl get pods -n "${PAAS_NS}" -o wide
  }
fi

HTTP_PAAS="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:${PAAS_PORT}/" 2>/dev/null || echo "000")"
echo "PaaS http://${NODE_IP}:${PAAS_PORT}/ → HTTP ${HTTP_PAAS}"

echo ""
echo "=== B. Jenkins build (required before simple-app deploy) ==="
echo "Option 1 — UI: http://${NODE_IP}:30090 → job paas-deploy → Build (project simple-app)"
echo "Option 2 — curl (needs JENKINS_USERNAME + JENKINS_API_TOKEN in ${ENV_FILE}):"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
  JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:30090}"
  if [[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" && "${JENKINS_API_TOKEN}" != your-jenkins-api-token ]]; then
    echo "Triggering Jenkins paas-deploy..."
    CRUMB_JSON="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
      "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo '{}')"
    CRUMB="$(echo "${CRUMB_JSON}" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
    FIELD="$(echo "${CRUMB_JSON}" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')"
    CURL_CRUMB=()
    [[ -n "${CRUMB}" && -n "${FIELD}" ]] && CURL_CRUMB=(-H "${FIELD}:${CRUMB}")
    curl -sS -X POST -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
      "${CURL_CRUMB[@]}" \
      "${JENKINS_URL}/job/paas-deploy/buildWithParameters?PROJECT_ID=${PROJECT_ID}&BRANCH=main" \
      -o /dev/null -w "Jenkins trigger HTTP %{http_code}\n" || true
    echo "Watch build: ${JENKINS_URL}/job/paas-deploy/lastBuild/console"
  else
    echo "Set JENKINS_USERNAME and JENKINS_API_TOKEN in ${ENV_FILE} to auto-trigger."
  fi
fi

echo ""
echo "=== C. After Jenkins SUCCESS — gate then deploy ==="
echo 'TAG=<build_number>   # from PAAS_ARTIFACT_IMAGE=.../simple-app:NNN'
echo 'curl -sS -o /dev/null -w "MAN %{http_code}\n" -I -u admin:Harbor12345 \'
echo "  \"http://${NODE_IP}:30002/v2/paas/simple-app/manifests/\${TAG}\""
echo "# MAN must be 200, then:"
echo "export GITHUB_TOKEN=ghp_..."
echo "bash ${REPO_ROOT}/paas/scripts/final-deploy-simple-app-lab.sh \${TAG}"
