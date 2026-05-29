#!/usr/bin/env bash
# Ultra lab fix: Jenkins executors, zombie builds, job settings, env, one clean pipeline path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
PAAS_NS="${PAAS_NS:-paas}"

upsert() {
  local k="$1" v="$2"
  [[ -f "${ENV_FILE}" ]] || return 0
  if grep -q "^${k}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${ENV_FILE}"
  else
    echo "${k}=${v}" >> "${ENV_FILE}"
  fi
}

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  PaaS ULTRA pipeline fix (executors + zombies + job + env)   ║"
echo "╚══════════════════════════════════════════════════════════════╝"

echo ""
echo "==> [1/8] Jenkins deployment up + 3Gi RAM (prevents npm ci OOM)"
if ! kubectl get deployment jenkins -n "${JENKINS_NS}" >/dev/null 2>&1; then
  echo "ERROR: no deployment/jenkins in ${JENKINS_NS}" >&2
  exit 1
fi
kubectl patch deployment jenkins -n "${JENKINS_NS}" --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"3Gi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"1536Mi"},
  {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"2000m"},
  {"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"-Xms512m -Xmx1536m -Djenkins.install.runSetupWizard=false -Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=86400"}
]' 2>/dev/null || true
kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=1
kubectl rollout status deployment/jenkins -n "${JENKINS_NS}" --timeout=600s

echo ""
echo "==> [2/8] Abort zombie builds on PVC (OOM resume leftovers)"
bash "${SCRIPT_DIR}/abort-jenkins-zombie-builds-lab.sh"

echo ""
echo "==> [3/8] Jenkins Script Console: 2 executors, no concurrent builds, clear queue"
if ! python3 "${SCRIPT_DIR}/jenkins-configure-lab.py"; then
  echo ""
  echo "WARN: Script Console failed (403 = use admin token)."
  echo "  1. Jenkins UI → admin → Security → Add new Token"
  echo "  2. JENKINS_USERNAME=admin + JENKINS_API_TOKEN in ${ENV_FILE}"
  echo "  3. Re-run: python3 paas/scripts/jenkins-configure-lab.py"
  echo ""
fi

echo ""
echo "==> [4/8] Job paas-deploy: empty agent label, disable concurrent, latest Jenkinsfile"
export JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo ""
echo "==> [5/8] PaaS env (full pipeline, no inline sync overwrite, empty agent label)"
upsert JENKINS_AGENT_LABEL ""
upsert JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
upsert JENKINS_PAAS_FAST_PIPELINE "false"
upsert JENKINS_NODE_MAX_OLD_SPACE_MB "2048"
upsert JENKINS_SH_KEEPALIVE "true"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true

echo ""
echo "==> [6/8] Security integrations (Sonar, DT, Cosign) — may take a few minutes"
if [[ -x "${SCRIPT_DIR}/setup-security-lab.sh" ]]; then
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/setup-security-lab.sh" || echo "WARN: setup-security partial — check SONAR_TOKEN / DEPENDENCY_TRACK_API_KEY"
fi

echo ""
echo "==> [7/8] Rebuild frontend (always send JENKINS_AGENT_LABEL= on trigger)"
bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"

echo ""
echo "==> [8/8] Reset stuck PaaS deployment rows"
kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -c \
  "UPDATE \"Deployment\" SET status='FAILED', \"failureMessage\"='Ultra fix reset — trigger one new deploy' WHERE status IN ('PENDING','DEPLOYING');" \
  2>/dev/null || true

echo ""
echo "==> Status"
bash "${SCRIPT_DIR}/jenkins-status-lab.sh" || true

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  READY — trigger exactly ONE deploy from PaaS UI             ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  • Console must NOT show 'Waiting for next available executor'║"
echo "║  • Must show Step 1 within ~30s                             ║"
echo "║  • Do NOT restart Jenkins during build (1–3h first run)       ║"
echo "║  • Use admin API token so Cancel works                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
