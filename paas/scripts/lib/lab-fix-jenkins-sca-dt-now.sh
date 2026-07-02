#!/usr/bin/env bash
# One shot: Jenkins up → DT API key fresh → CPS monolith on pod → job params synced.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JNS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
REMOTE="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
IN_CLUSTER_DT="http://dtrack-dependency-track-api-server.dependency-track.svc.cluster.local:8080"

echo "==> 1/4 Jenkins recover (HTTP :30090 — required for job POST)"
bash "${SCRIPT_DIR}/lab-jenkins-recover.sh" recover || {
  echo "FAIL: Jenkins not up — check: kubectl get pods -n ${JNS}" >&2
  exit 1
}

echo "==> 2/4 Dependency-Track API key + env (auto-bootstrap if NodePort/key stale)"
if ! bash "${SCRIPT_DIR}/lab-dependency-track.sh"; then
  echo "==> dependency-track heal failed — dt-bootstrap (new API key)"
  bash "${SCRIPT_DIR}/bootstrap-dependency-track-lab.sh"
fi

echo "==> 3/4 Jenkins ZAP + DT port-forward RBAC"
bash "${SCRIPT_DIR}/lab-jenkins-zap-tools.sh"

echo "==> 4/4 Push CPS monolith to Jenkins pod + POST wrapper"
SKIP_HARBOR_FIX_PUSH=1 SKIP_DT_HEAL=1 bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"

echo "==> Verify live Jenkins markers"
for m in dt-cluster-first-20260702 dt-listfile-posix-20260701 dt_kubectl_portforward_upload; do
  kubectl exec -n "${JNS}" "${JPOD}" -c jenkins --request-timeout=60s -- \
    grep -q "${m}" "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null \
    || echo "WARN: marker ${m} not in monolith — git pull Jenkinsfile.paas-deploy && re-run" >&2
done

if [[ -f "${ENV_FILE}" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${ENV_FILE}" 2>/dev/null || true
  set +a
  export JENKINS_DEPENDENCY_TRACK_BASE_URL="${JENKINS_DEPENDENCY_TRACK_BASE_URL:-${IN_CLUSTER_DT}}"
  python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force \
    || echo "WARN: Jenkins param sync skipped (Jenkins HTTP?)"
fi

echo ""
echo "==> Probes"
for port in 30090 32336; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 "http://${NODE_IP}:${port}/" 2>/dev/null || echo 000)"
  echo "  :${port} => HTTP ${code}"
done
kubectl exec -n "${JNS}" "${JPOD}" -c jenkins --request-timeout=30s -- \
  curl -fsS -m 15 "${IN_CLUSTER_DT}/api/version" 2>/dev/null \
  && echo "  Jenkins pod -> DT in-cluster: OK" \
  || echo "  WARN: Jenkins pod -> DT in-cluster failed (Step 4 uses kubectl port-forward fallback)"

echo ""
echo "OK — trigger NEW paas-deploy from http://${NODE_IP}:30090 or PaaS UI"
echo "Console must show: marker=dt-cluster-first-20260702"
