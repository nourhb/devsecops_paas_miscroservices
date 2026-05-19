#!/usr/bin/env bash
# Full lab recovery: Harbor blobs + PaaS frontend + Jenkins simple-app deploy.
#
# Why Jenkins #100 "Success" but MAN 404?
#   Build ran before registry PVC was recreated — DB metadata exists, blobs do not.
#
# Usage:
#   bash paas/scripts/lab-recover-all.sh
#   # After Jenkins finishes (new build number NNN):
#   export GITHUB_TOKEN=ghp_...
#   bash paas/scripts/final-deploy-simple-app-lab.sh NNN
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
PAAS_NS="${PAAS_NS:-paas}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROJECT_ID="${PROJECT_ID:-179dcf7f-ad21-4421-9114-0171f3e9914c}"
ENV_FILE="${REPO_ROOT}/paas/frontend/docker-compose.env"

man_tag() {
  local repo="$1" tag="$2"
  curl -sS -o /dev/null -w '%{http_code}' -I -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "http://${HARBOR}/v2/${repo}/manifests/${tag}" 2>/dev/null || echo "000"
}

echo "========== STEP 1: Harbor registry must be Running =========="
kubectl get pods -n harbor -l app=harbor,component=registry -o wide
kubectl wait --for=condition=ready pod -l app=harbor,component=registry -n harbor --timeout=120s
V2="$(curl -sS -o /dev/null -w '%{http_code}' -I "http://${HARBOR}/v2/")"
echo "Harbor /v2/ → HTTP ${V2} (expect 401)"
[[ "$V2" == "401" || "$V2" == "200" ]] || exit 1

echo ""
echo "========== STEP 2: Ghost metadata (skip by default) =========="
if [[ "${PURGE_HARBOR_REPOS:-}" == "1" ]]; then
  for repo in paas/simple-app paas/paas-frontend; do
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -u "${HARBOR_USER}:${HARBOR_PASS}" \
      "http://${HARBOR}/api/v2.0/projects/paas/repositories/$(basename "$repo")" 2>/dev/null || echo "000")"
    echo "DELETE ${repo} → HTTP ${CODE}"
  done
  sleep 3
else
  echo "Skipping Harbor repo DELETE (set PURGE_HARBOR_REPOS=1 to purge ghost metadata)"
fi

echo ""
echo "========== STEP 3: PaaS frontend (build + k3s import; Harbor push optional) =========="
bash "${REPO_ROOT}/paas/scripts/fix-paas-frontend-pull-lab.sh"
FE_MAN="$(man_tag paas/paas-frontend latest)"
echo "paas-frontend:latest MAN (curl) → HTTP ${FE_MAN} (200 = Harbor OK; UI can work with MAN 404 if import succeeded)"

echo ""
echo "========== STEP 4: k3s HTTP registry on ALL nodes =========="
echo "If frontend still ImagePullBackOff, on master + worker1 + worker2 console run:"
echo "  sudo tee /etc/rancher/k3s/registries.yaml <<'EOF'"
echo 'mirrors:'
echo "  \"${HARBOR}\":"
echo '    endpoint:'
echo "      - \"http://${HARBOR}\""
echo 'configs:'
echo "  \"${HARBOR}\":"
echo '    auth:'
echo "      username: ${HARBOR_USER}"
echo "      password: ${HARBOR_PASS}"
echo '    tls:'
echo '      insecure_skip_verify: true'
echo 'EOF'
echo "  sudo systemctl restart k3s || sudo systemctl restart k3s-agent"
echo ""
HTTP_PAAS="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:30100/" 2>/dev/null || echo "000")"
echo "PaaS UI http://${NODE_IP}:30100/ → HTTP ${HTTP_PAAS}"

echo ""
echo "========== STEP 5: NEW Jenkins build (do NOT reuse tag 100) =========="
echo "Old build #100 succeeded but blobs were lost when registry PVC was recreated."
if [[ -f "${ENV_FILE}" ]]; then
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
  JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:30090}"
  if [[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
    CRUMB_JSON="$(curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${JENKINS_URL}/crumbIssuer/api/json" 2>/dev/null || echo '{}')"
    CRUMB="$(echo "${CRUMB_JSON}" | sed -n 's/.*"crumb":"\([^"]*\)".*/\1/p')"
    FIELD="$(echo "${CRUMB_JSON}" | sed -n 's/.*"crumbRequestField":"\([^"]*\)".*/\1/p')"
    CURL_CRUMB=(); [[ -n "$CRUMB" && -n "$FIELD" ]] && CURL_CRUMB=(-H "${FIELD}:${CRUMB}")
    curl -sS -X POST -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" "${CURL_CRUMB[@]}" \
      "${JENKINS_URL}/job/paas-deploy/buildWithParameters?PROJECT_ID=${PROJECT_ID}&BRANCH=main" \
      -o /dev/null -w "Jenkins trigger → HTTP %{http_code}\n"
    echo "Console: ${JENKINS_URL}/job/paas-deploy/lastBuild/console"
  fi
fi

echo ""
echo "========== STEP 6: After Jenkins SUCCESS =========="
echo 'TAG=<new_build_number>  # from PAAS_ARTIFACT_IMAGE line'
echo 'curl -sS -o /dev/null -w "MAN %{http_code}\n" -I -u admin:Harbor12345 \'
echo "  \"http://${HARBOR}/v2/paas/simple-app/manifests/\${TAG}\""
echo "# MAN must be 200, then:"
echo "export GITHUB_TOKEN=ghp_..."
echo "bash ${REPO_ROOT}/paas/scripts/final-deploy-simple-app-lab.sh \${TAG}"
