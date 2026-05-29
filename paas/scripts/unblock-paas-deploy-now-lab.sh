#!/usr/bin/env bash
# Unblock paas-deploy NOW: free executors, kill zombies, verify idle slot.
# Run when console shows "Waiting for next available executor" > 1 min.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"

set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u

echo "==> 1. Jenkins up"
kubectl scale deployment/jenkins -n "${JENKINS_NS}" --replicas=1 2>/dev/null || true
kubectl rollout status deployment/jenkins -n "${JENKINS_NS}" --timeout=600s 2>/dev/null || true
for i in $(seq 1 24); do
  curl -fsS "${JENKINS_PROBE_URL:-http://127.0.0.1:30090}/api/json" >/dev/null 2>&1 && break
  sleep 5
done

echo "==> 2. Kill zombie builds on disk (OOM leftovers)"
bash "${SCRIPT_DIR}/abort-jenkins-zombie-builds-lab.sh"

echo "==> 3. Script Console: 2 executors, clear queue, stop any building run"
if ! python3 "${SCRIPT_DIR}/jenkins-configure-lab.py"; then
  echo ""
  echo "FAIL: need admin token in ${ENV_FILE}:"
  echo "  JENKINS_USERNAME=admin"
  echo "  JENKINS_API_TOKEN=<Jenkins → admin → Security → Add new Token>"
  exit 1
fi

echo "==> 4. Job settings (abortPrevious + empty agent label)"
export JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo "==> 5. Status (need idle executor before new deploy)"
bash "${SCRIPT_DIR}/jenkins-status-lab.sh"

BUILDING="$(python3 <<'PY' "${JENKINS_PROBE_URL:-http://127.0.0.1:30090}" "${JENKINS_USERNAME}" "${JENKINS_API_TOKEN}"
import json, sys, urllib.request, base64
base, user, token = sys.argv[1:4]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
req = urllib.request.Request(
    f"{base.rstrip('/')}/job/paas-deploy/api/json?tree=builds[number,building]",
    headers={"Authorization": f"Basic {auth}"},
)
with urllib.request.urlopen(req, timeout=30) as r:
    data = json.load(r)
print(sum(1 for b in data.get("builds", []) if b.get("building")))
PY
)"

if [[ "${BUILDING}" != "0" ]]; then
  echo ""
  echo "WARN: still ${BUILDING} build(s) marked building — cancel #90 in Jenkins UI (×), then re-run this script."
  exit 1
fi

echo ""
echo "OK — executors free. Trigger ONE deploy from PaaS (not while another is blue)."
echo "For faster lab builds (skip Step 3/4/5): JENKINS_PAAS_FAST_PIPELINE=true in docker-compose.env + sync env."
