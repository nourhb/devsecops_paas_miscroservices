#!/usr/bin/env bash
# One-shot lab recovery: Jenkins zombies, memory, security env, pipeline, stuck PaaS rows.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
PAAS_NS="${PAAS_NS:-paas}"

echo "=== PaaS lab fix-all ==="

echo "==> 1. Jenkins memory (3Gi — prevents OOM during npm ci)"
kubectl patch deployment jenkins -n "${JENKINS_NS}" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"1536Mi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"2000m"},
  {"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"-Xms512m -Xmx1536m -Djenkins.install.runSetupWizard=false -Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=86400"}
]' 2>/dev/null || echo "WARN: Jenkins patch skipped (no deployment?)"

echo "==> 2. Abort zombie builds (#82, #83, …)"
if ! bash "${SCRIPT_DIR}/abort-jenkins-zombie-builds-lab.sh"; then
  echo "WARN: zombie abort had errors — ensure Jenkins is up: kubectl get deploy -n ${JENKINS_NS} jenkins"
  kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=1 2>/dev/null || true
  kubectl rollout status deployment/jenkins -n "${JENKINS_NS}" --timeout=600s 2>/dev/null || true
fi

echo "==> 3. Security + full pipeline (Sonar, DT, Cosign, JENKINS_PAAS_FAST_PIPELINE=false)"
if [[ -x "${SCRIPT_DIR}/setup-security-lab.sh" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/setup-security-lab.sh"
else
  echo "WARN: setup-security-lab.sh missing — git pull"
fi

echo "==> 4. Jenkins agent label + inline sync off"
upsert() {
  local k="$1" v="$2"
  [[ -f "${ENV_FILE}" ]] || return 0
  if grep -q "^${k}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${ENV_FILE}"
  else
    echo "${k}=${v}" >> "${ENV_FILE}"
  fi
}
upsert JENKINS_AGENT_LABEL ""
upsert JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
upsert JENKINS_NODE_MAX_OLD_SPACE_MB "2048"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo "==> 5. Reset stuck PaaS deployments"
kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -c \
  "UPDATE \"Deployment\" SET status='FAILED', \"failureMessage\"='Lab fix-all reset' WHERE status IN ('PENDING','DEPLOYING');" \
  2>/dev/null || bash "${SCRIPT_DIR}/fix-stuck-paas-deployments-lab.sh" 2>/dev/null || true

echo "==> 6. Rebuild frontend (Sonar projectKey fix in API)"
if [[ -x "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh" ]]; then
  bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"
else
  echo "WARN: deploy-paas-frontend-k8s.sh missing — run manually after git pull"
fi

echo ""
echo "=== Manual (once) ==="
echo "  • Jenkins UI → admin → API token → set JENKINS_USERNAME=admin + JENKINS_API_TOKEN in ${ENV_FILE}"
echo "  • bash paas/scripts/sync-paas-frontend-env-k8s.sh"
echo "  • Manage Jenkins → System + Built-In Node → # executors = 2"
echo ""
echo "=== Then ==="
echo "  • ONE deploy from PaaS (full pipeline ~1–3h first time)"
echo "  • Do NOT restart Jenkins during Step 3/6"
echo "  • After SUCCESS: refresh Security page (Sonar key = project UUID, not simple-app)"
echo ""
bash "${SCRIPT_DIR}/jenkins-status-lab.sh" 2>/dev/null | tail -25 || true
