#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JOB="${JENKINS_JOB_NAME:-paas-deploy}"
JOB_CFG="/var/jenkins_home/jobs/${JOB}/config.xml"
TMP_CFG="/tmp/paas-deploy-config.xml"

cd "${REPO_ROOT}"
set -a
source "${ENV_FILE}" 2>/dev/null || true
set +a
[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "ERROR: set JENKINS_USERNAME + JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
}

echo "==> Read job config from Jenkins pod (disk)"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  cat "${JOB_CFG}" > "${TMP_CFG}"

if grep -qF 'missing runPaasDeploy in p3' "${TMP_CFG}"; then
  echo "ERROR: disk config.xml still has OLD stale check — fix wrapper on disk first" >&2
  exit 1
fi
if ! grep -qF 'runPaasDeployEnvInit()' "${TMP_CFG}"; then
  echo "ERROR: disk config.xml missing inline step calls after loads" >&2
  exit 1
fi

echo "==> POST disk config to Jenkins LIVE (in-memory)"
export TMP_CFG
FORCE_POST=1 VERIFY_ONLY=0 bash "${SCRIPT_DIR}/reload-jenkins-paas-deploy-job.sh"

echo "==> Verify LIVE via API (not just PVC disk)"
python3 <<'PY'
import base64, json, os, sys, urllib.request, http.cookiejar
from pathlib import Path

env = Path("paas/frontend/docker-compose.env").read_text(encoding="utf-8", errors="replace")
vals = {}
for line in env.splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        vals[k.strip()] = v.strip()
base = (vals.get("JENKINS_PROBE_URL") or vals.get("JENKINS_BASE_URL") or "http://192.168.56.129:30090").rstrip("/")
user = vals.get("JENKINS_USERNAME") or vals.get("JENKINS_USER") or ""
token = vals.get("JENKINS_API_TOKEN") or vals.get("JENKINS_TOKEN") or ""
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
req = urllib.request.Request(
    f"{base}/job/paas-deploy/config.xml",
    headers={"Authorization": f"Basic {auth}"},
)
live = urllib.request.urlopen(req, timeout=60).read().decode("utf-8", "replace")
if "missing runPaasDeploy in p3" in live:
    sys.exit("FAIL: Jenkins LIVE still has old wrapper (missing runPaasDeploy check)")
if "load paasStagesP3" not in live or "runPaasDeploy()" not in live:
    sys.exit("FAIL: Jenkins LIVE missing 7-file CPS wrapper (load paasStagesP3 + runPaasDeploy)")
print("OK: Jenkins LIVE config verified (7-file CPS split + runPaasDeploy)")
PY

echo ""
echo "Safe to trigger NEW paas-deploy build."
