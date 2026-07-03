#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

patch_env_key() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" ]] || touch "${file}"
  if grep -qE "^${key}=" "${file}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

ensure_lab_env_defaults() {
  for f in "${DOT_ENV}" "${ENV_FILE}"; do
    patch_env_key "${f}" "JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER" "false"
    patch_env_key "${f}" "PAAS_DT_UPLOAD_OPTIONAL" "true"
    patch_env_key "${f}" "JENKINS_NEXT_BUILD_WEBPACK" "true"
  done
  echo "OK: lab defaults (PAAS_DT_UPLOAD_OPTIONAL=true, JENKINS_NEXT_BUILD_WEBPACK=true, inline sync off)"
}

preflight() {
  local fail=0 dt_http sonar_ok kctl_ok marker_ok
  set -a
  source "${ENV_FILE}" 2>/dev/null || true
  set +a
  dt_http="$(curl -sS -o /dev/null -w '%{http_code}' -m 12 \
    -H "X-Api-Key: ${DEPENDENCY_TRACK_API_KEY:-}" \
    "${DEPENDENCY_TRACK_BASE_URL:-http://${NODE_IP}:32336}/api/v1/project?pageNumber=1&pageSize=1" \
    2>/dev/null || echo 000)"
  if [[ "${dt_http}" == "200" ]]; then
    echo "OK: DT API key valid (HTTP 200)"
  else
    echo "WARN: DT API key HTTP ${dt_http} — Step 4 will WARN (401) but pipeline continues"
    fail=1
  fi
  sonar_ok="$(curl -sS -m 12 -u "${SONAR_TOKEN:-x}:" \
    "${SONAR_BASE_URL:-http://${NODE_IP}:30900}/api/authentication/validate" 2>/dev/null \
    | grep -c '"valid":true' || true)"
  if [[ "${sonar_ok}" -ge 1 ]]; then
    echo "OK: Sonar token valid"
  else
    echo "WARN: Sonar token invalid — Step 5 may fail until sonar-bootstrap succeeds"
    fail=1
  fi
  if kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c jenkins --request-timeout=45s -- \
    sh -c '/var/jenkins_home/bin/kubectl version --client >/dev/null 2>&1' 2>/dev/null; then
    echo "OK: kubectl in Jenkins pod (working)"
  else
    echo "WARN: kubectl missing/broken in Jenkins pod
    fail=1
  fi
  if kubectl get clusterrolebinding jenkins-lab-ram-pause >/dev/null 2>&1; then
    echo "OK: RAM-pause RBAC present (frontend/harbor/dependency-track scale during Sonar)"
  else
    echo "WARN: RAM-pause RBAC missing
    fail=1
  fi
  marker_ok="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c jenkins --request-timeout=45s -- \
    grep -c 'dt-nodeport-first-lab-20260702' /var/jenkins_home/paas/paas-deploy-stages.groovy 2>/dev/null \
    | tr -d '\r\n' | tail -1)" || marker_ok=0
  if [[ "${marker_ok}" -ge 1 ]]; then
    echo "OK: dt-nodeport-first-lab marker on Jenkins pod"
  else
    echo "WARN: Jenkins pod missing dt-nodeport-first-lab marker — CPS bundle stale"
    fail=1
  fi
  return "${fail}"
}

echo "=============================================="
echo " FORCE READY — paas-deploy (break failure loop)"
echo "=============================================="

echo "==> 1/6 sync-repo (VM must match GitHub main)"
bash "${REPO_ROOT}/paas/scripts/lab.sh" sync-repo

echo "==> 2/6 lab env defaults"
ensure_lab_env_defaults

echo "==> 3/6 fix-paas-deploy (CPS bundle + DT/Sonar/kubectl heal)"
export PAAS_DT_UPLOAD_OPTIONAL=true
export JENKINS_NEXT_BUILD_WEBPACK=true
bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"

echo "==> 4/6 POST CPS wrapper to Jenkins LIVE (anti-revert)"
bash "${SCRIPT_DIR}/force-api-jenkins-paas-deploy-now.sh"

echo "==> 5/6 Jenkins job params (DT key + optional=true + webpack=true)"
set -a
source "${ENV_FILE}" 2>/dev/null || true
set +a
export PAAS_DT_UPLOAD_OPTIONAL=true
export JENKINS_NEXT_BUILD_WEBPACK=true
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only --force

if command -v kubectl >/dev/null 2>&1 && kubectl get secret paas-frontend-env -n paas >/dev/null 2>&1; then
  echo "==> 5b/6 sync frontend env secret"
  PAAS_SKIP_ROLLOUT=0 ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" \
    || echo "WARN: frontend env sync failed"
fi

echo "==> 6/6 preflight"
if preflight; then
  echo ""
  echo "=============================================="
  echo " READY — trigger a new paas-deploy build"
  echo "=============================================="
else
  echo ""
  echo "=============================================="
  echo " PARTIAL — fixes applied; some preflight checks failed."
  echo " Re-run: bash paas/scripts/lab.sh deploy-now"
  echo " Or fix warnings above, then trigger NEW build (not Replay)"
  echo "=============================================="
  exit 1
fi
