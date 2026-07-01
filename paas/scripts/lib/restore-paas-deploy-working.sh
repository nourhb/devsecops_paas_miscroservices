#!/usr/bin/env bash
# ONE SHOT: restore paas-deploy (7-file CPS split + runPaasDeploy — avoids MethodTooLarge).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

echo "=============================================="
echo " RESTORE paas-deploy (7-file CPS split layout)"
echo "=============================================="

set -a
# shellcheck disable=SC1091
source "${ENV_FILE}" 2>/dev/null || true
set +a

echo "==> 1/4 Install 7-file CPS bundle on Jenkins pod"
SKIP_JOB_PATCH=1 bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> 2/4 POST 7-file CPS wrapper to Jenkins LIVE"
python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py"

echo "==> 3/4 Disable UI job revert + sync params"
for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
  [[ -f "${f}" ]] || continue
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${f}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${f}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${f}"
  fi
done
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only 2>/dev/null || true

echo "==> 4/4 Verify LIVE job (7 loads + runPaasDeploy, NOT monolith load)"
python3 <<'PY'
import base64, os, sys, urllib.request
from pathlib import Path

sys.path.insert(0, "paas/scripts/lib")
from jenkins_merge_cps_wrapper import live_wrapper_ok

vals = {}
for line in Path("paas/frontend/docker-compose.env").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("=")
        vals[k.strip()] = v.strip().strip('"')
base = (os.environ.get("JENKINS_PROBE_URL") or vals.get("JENKINS_PROBE_URL") or "http://192.168.56.129:30090").rstrip("/")
user = os.environ.get("JENKINS_USERNAME") or vals.get("JENKINS_USERNAME")
token = os.environ.get("JENKINS_API_TOKEN") or vals.get("JENKINS_API_TOKEN")
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
live = urllib.request.urlopen(
    urllib.request.Request(f"{base}/job/paas-deploy/config.xml", headers={"Authorization": f"Basic {auth}"}),
    timeout=60,
).read().decode()
bad = live_wrapper_ok(live)
if bad:
    print("FAIL:", file=sys.stderr)
    for b in bad:
        print(f"  - {b}", file=sys.stderr)
    sys.exit(1)
print("OK: LIVE job uses 7-file CPS load + runPaasDeploy()")
PY

echo ""
echo "=============================================="
echo " DONE — trigger NEW paas-deploy build (not Replay)"
echo ""
echo " Console MUST show:"
echo "   marker=${CPS_MARKER}"
echo "   SEVEN [Pipeline] load lines"
echo "   runPaasDeploy()"
echo "   *** BEGIN : Check Parameters ***"
echo "=============================================="
