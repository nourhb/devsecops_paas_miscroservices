#!/usr/bin/env bash
# Test Sonar reachability + token from the Jenkins agent pod (same network as Step 5).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../frontend/docker-compose.env}"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a

NS="${JENKINS_NS:-cicd}"
POD="$(kubectl get pod -n "${NS}" -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${POD}" ]] || { echo "ERROR: no Jenkins pod in ${NS}" >&2; exit 1; }

echo "==> Jenkins pod: ${NS}/${POD}"
for URL in \
  "${SONAR_BASE_URL:-}" \
  "${SONAR_HOST_URL:-}" \
  "http://sonarqube-service.sonarqube.svc.cluster.local:9000"; do
  [[ -z "${URL}" ]] && continue
  echo "--- probe ${URL}"
  kubectl exec -n "${NS}" "${POD}" -- sh -c "
    curl -sS -m 10 -u '${SONAR_TOKEN}:' '${URL%/}/api/authentication/validate' || echo FAIL
    curl -sS -m 10 '${URL%/}/api/system/status' | head -c 120 || echo FAIL
  " 2>/dev/null || echo "exec failed"
done

echo ""
echo "If NodePort fails but cluster URL works, sync Jenkinsfile and redeploy:"
echo "  bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "  bash paas/scripts/sync-paas-jenkinsfile-configmap-k8s.sh"
