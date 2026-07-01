#!/usr/bin/env bash
# Nuclear fix: install CPS bundle + POST correct 7-file wrapper to Jenkins LIVE via REST API.
# Use when disk config.xml looks fine but builds still show "Stale stages bundle (missing runPaasDeploy in p3)".
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JOB="${JENKINS_JOB_NAME:-paas-deploy}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

echo "=============================================="
echo " FORCE API: paas-deploy wrapper + CPS bundle"
echo "=============================================="

echo "==> 1/4 Install 7-file CPS bundle on Jenkins pod"
SKIP_JOB_PATCH=1 bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> 2/4 Disable UI inline job sync (stops reverting wrapper)"
for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
  [[ -f "${f}" ]] || continue
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${f}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${f}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${f}"
  fi
done

echo "==> 3/4 POST correct CPS wrapper to Jenkins LIVE (CDATA or XML-escaped script)"
python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py"

# Also refresh params if create_jenkins exists
if [[ -f "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" ]]; then
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only 2>/dev/null || true
fi

echo "==> 4/4 Verify LIVE config + p3 bundle"
python3 <<'PY'
import base64
import json
import os
import re
import sys
import urllib.request
import http.cookiejar
from pathlib import Path

sys.path.insert(0, "paas/scripts/lib")
from jenkins_merge_cps_wrapper import live_wrapper_ok

def load_env(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    if not path.is_file():
        return out
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip().strip('"')
    return out

vals = load_env(Path("paas/frontend/docker-compose.env"))
base = (
    os.environ.get("JENKINS_PROBE_URL")
    or os.environ.get("JENKINS_BASE_URL")
    or vals.get("JENKINS_PROBE_URL")
    or vals.get("JENKINS_BASE_URL")
    or "http://192.168.56.129:30090"
).rstrip("/")
user = os.environ.get("JENKINS_USERNAME") or vals.get("JENKINS_USERNAME") or vals.get("JENKINS_USER") or ""
token = os.environ.get("JENKINS_API_TOKEN") or vals.get("JENKINS_API_TOKEN") or vals.get("JENKINS_TOKEN") or ""
if not user or not token:
    sys.exit("FAIL: JENKINS_USERNAME / JENKINS_API_TOKEN not set")

auth = base64.b64encode(f"{user}:{token}".encode()).decode()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
crumb = json.loads(
    opener.open(
        urllib.request.Request(f"{base}/crumbIssuer/api/json", headers={"Authorization": f"Basic {auth}"})
    ).read()
)
live = opener.open(
    urllib.request.Request(
        f"{base}/job/paas-deploy/config.xml",
        headers={"Authorization": f"Basic {auth}", crumb["crumbRequestField"]: crumb["crumb"]},
    )
).read().decode("utf-8", "replace")

bad = live_wrapper_ok(live)

# p3 on pod (StatefulSet jenkins-0, not deploy/jenkins)
import subprocess
ns = os.environ.get("JENKINS_K8S_NAMESPACE", "cicd")
jpod = subprocess.run(
    ["kubectl", "get", "pods", "-n", ns, "-l", "app.kubernetes.io/component=jenkins-controller",
     "-o", "jsonpath={.items[0].metadata.name}"],
    capture_output=True, text=True, timeout=60,
).stdout.strip() or "jenkins-0"
p3 = subprocess.run(
    ["kubectl", "exec", "-n", ns, jpod, "-c", "jenkins", "--",
     "cat", "/var/jenkins_home/paas/paas-deploy-stages-p3.groovy"],
    capture_output=True,
    text=True,
    timeout=120,
)
if p3.returncode != 0:
    bad.append(f"cannot read p3 on pod: {p3.stderr[:200]}")
elif "def runPaasDeploy()" not in p3.stdout:
    bad.append("p3 on pod missing def runPaasDeploy() — re-run install-jenkins-stages-file")
elif re.search(r"^runPaasDeploy\(\)\s*$", p3.stdout, re.M):
    bad.append("p3 still has self-invoke runPaasDeploy() at EOF — re-render bundle")

if bad:
    print("FAIL: verification failed:", file=sys.stderr)
    for b in bad:
        print(f"  - {b}", file=sys.stderr)
    sys.exit(1)

print("OK: Jenkins LIVE has 7-file CPS wrapper + valid p3")
PY

# Sync disk config.xml from LIVE so PVC matches memory
# shellcheck source=lab-jenkins-pod.sh
source "${SCRIPT_DIR}/lab-jenkins-pod.sh"
jenkins_exec "${JENKINS_NS}" test -f "/var/jenkins_home/jobs/${JOB}/config.xml" || true
python3 <<'PY'
import base64, json, os, urllib.request, http.cookiejar
from pathlib import Path

vals = {}
for line in Path("paas/frontend/docker-compose.env").read_text(encoding="utf-8", errors="replace").splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        vals[k.strip()] = v.strip().strip('"')
base = (vals.get("JENKINS_PROBE_URL") or vals.get("JENKINS_BASE_URL") or "http://192.168.56.129:30090").rstrip("/")
user = vals.get("JENKINS_USERNAME") or vals.get("JENKINS_USER") or ""
token = vals.get("JENKINS_API_TOKEN") or vals.get("JENKINS_TOKEN") or ""
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
live = urllib.request.urlopen(
    urllib.request.Request(f"{base}/job/paas-deploy/config.xml", headers={"Authorization": f"Basic {auth}"}),
    timeout=60,
).read()
Path("/tmp/paas-deploy-config-live.xml").write_bytes(live)
print(f"OK: saved LIVE config ({len(live)} bytes) -> /tmp/paas-deploy-config-live.xml")
PY
kubectl exec -i -n "${JENKINS_NS}" "$(jenkins_pod_name "${JENKINS_NS}")" -c jenkins --request-timeout=120s -- \
  tee "/var/jenkins_home/jobs/${JOB}/config.xml" < /tmp/paas-deploy-config-live.xml >/dev/null
echo "OK: PVC config.xml synced from LIVE"

echo ""
echo "=============================================="
echo " DONE — trigger NEW paas-deploy build (not Replay)"
echo " Console MUST show:"
echo "   marker=${CPS_MARKER}"
echo "   SEVEN [Pipeline] load lines"
echo "   runPaasDeploy()  (after loads, NOT inside load p3)"
echo "   *** BEGIN : Check Parameters ***"
echo "=============================================="
