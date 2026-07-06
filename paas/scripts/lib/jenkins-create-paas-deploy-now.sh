#!/usr/bin/env bash
# Lab helper script for jenkins create paas deploy now
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:${JENKINS_NODEPORT}}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

ADMIN_PW="$(kubectl exec -n "${JENKINS_NS}" jenkins-0 -c jenkins --request-timeout=60s \
  cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r\n' || true)"
if [[ -z "${ADMIN_PW}" && -n "${JENKINS_API_TOKEN:-}" ]]; then
  ADMIN_PW="${JENKINS_API_TOKEN}"
fi
[[ -n "${ADMIN_PW}" ]] || fail "could not read chart admin password — export JENKINS_API_TOKEN first"

export JENKINS_USERNAME="${JENKINS_USERNAME:-admin}"
export JENKINS_API_TOKEN="${JENKINS_API_TOKEN:-${ADMIN_PW}}"
export JENKINS_BASE_URL="${JENKINS_BASE_URL:-${JENKINS_URL}}"
export JENKINS_PROBE_URL="${JENKINS_PROBE_URL:-${JENKINS_URL}}"

echo "==> Auth check"
code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/api/json" || echo 000)"
[[ "${code}" == "200" ]] || fail "Jenkins auth HTTP ${code} at ${JENKINS_URL}"

echo "==> Pipeline plugins (workflow-aggregator — required for createItem)"
if [[ -f "${SCRIPT_DIR}/install-jenkins-workflow-plugins.sh" ]]; then
  bash "${SCRIPT_DIR}/install-jenkins-workflow-plugins.sh" || fail "pipeline plugin install failed"
elif [[ -f "${SCRIPT_DIR}/lab-jenkins-pipeline-plugins.sh" ]]; then
  bash "${SCRIPT_DIR}/lab-jenkins-pipeline-plugins.sh" || fail "pipeline plugin install failed"
else
  python3 "${SCRIPT_DIR}/create-paas-deploy-job-api.py" --plugins-only 2>/dev/null || true
fi

job_code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/paas-deploy/api/json" || echo 000)"
if [[ "${job_code}" == "200" ]]; then
  ok "job paas-deploy already exists"
else
  echo "==> Create job (try API script — verbose)"
  if ! python3 "${SCRIPT_DIR}/create-paas-deploy-job-api.py"; then
    echo "==> API script failed — trying create_jenkins_paas_deploy_job.py --force"
    if ! python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force; then
      echo "==> Full create failed — trying --minimal --force"
      python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --minimal --force
    fi
  fi
  job_code="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
    "${JENKINS_URL}/job/paas-deploy/api/json" || echo 000)"
  [[ "${job_code}" == "200" ]] || fail "paas-deploy still HTTP ${job_code} — see output above"
  ok "job paas-deploy created"
fi

echo "==> Install CPS bundle on Jenkins pod"
bash "${SCRIPT_DIR}/install-cps-bundle-jenkins-0.sh" 2>/dev/null || \
  bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh" || true

echo "==> Sync job wrapper + parameters"
if python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py"; then
  ok "wrapper posted"
elif python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force; then
  ok "full job config pushed"
else
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only --force || \
    fail "wrapper sync failed
fi

echo "==> Verify"
curl -sS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_URL}/job/paas-deploy/api/json" | head -c 280
echo
ok "done — trigger deploy from PaaS UI"
