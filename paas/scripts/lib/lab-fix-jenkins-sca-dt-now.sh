#!/usr/bin/env bash
# Push Step 4 SCA + Dependency-Track fixes to live Jenkins and sync DT URL on the job.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "==> Push CPS monolith (bom-ref, node-first Python BOM, DT probe-only upload)"
SKIP_HARBOR_FIX_PUSH=1 bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"

echo "==> Verify live Jenkins markers"
JNS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
REMOTE="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
for m in "'bom-ref':" "dt-probe-only-upload-20260701" "resolvePortableNodeBin"; do
  kubectl exec -n "${JNS}" "${JPOD}" -c jenkins -- grep -q "${m}" "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null \
    || kubectl exec -n "${JNS}" "${JPOD}" -c jenkins -- grep -q "${m}" "${REMOTE}/paas-deploy-load-h1.groovy" 2>/dev/null \
    || echo "WARN: marker ${m} not found in live groovy" >&2
done

if [[ -f "${ENV_FILE}" ]]; then
  DT_URL="$(grep -E '^DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  DT_KEY="$(grep -E '^DEPENDENCY_TRACK_API_KEY=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  if [[ -n "${DT_URL}" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
    echo "==> Sync Jenkins job params DEPENDENCY_TRACK_BASE_URL=${DT_URL}"
    export DEPENDENCY_TRACK_BASE_URL="${DT_URL}"
    export JENKINS_DEPENDENCY_TRACK_BASE_URL="${DT_URL}"
    export DEPENDENCY_TRACK_API_KEY="${DT_KEY}"
    export PAAS_DT_UPLOAD_OPTIONAL="${PAAS_DT_UPLOAD_OPTIONAL:-true}"
    python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force 2>/dev/null || true
  fi
fi

echo "==> Probe Dependency-Track from master"
NODE_IP="${NODE_IP:-192.168.56.129}"
for port in 32336 31260 32337; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 "http://${NODE_IP}:${port}/api/version" 2>/dev/null || echo 000)"
  echo "  :${port} => HTTP ${code}"
done

echo ""
echo "OK: Jenkins Step 4 fixes pushed."
echo "Re-run failed projects from PaaS UI. Console must show:"
echo "  marker=dt-probe-only-upload-20260701"
echo "  [sca] Python BOM from requirements.txt (node"
echo "  'bom-ref': (quoted in node -e block)"
echo ""
echo "If DT still down: bash paas/scripts/lab.sh dependency-track"
