#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JUNE17_COMMIT="${JUNE17_COMMIT:-bb1fef3}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "=============================================="
echo " Roll back to June 17 2026 (build #756 era)"
echo " Target commit: ${JUNE17_COMMIT}"
echo "=============================================="

if [[ "${LAB_ROLLBACK_CONFIRM:-}" != "1" ]]; then
  echo ""
  echo "Restores the last known-stable Jenkins paas-deploy layout (17 Jun 2026)."
  echo ""
  echo "  LAB_ROLLBACK_CONFIRM=1 bash paas/scripts/lab.sh rollback-june17"
  echo ""
  exit 1
fi

cd "${REPO_ROOT}"
git fetch origin 2>/dev/null || true
if ! git cat-file -e "${JUNE17_COMMIT}^{commit}" 2>/dev/null; then
  echo "ERROR: commit ${JUNE17_COMMIT} not found — git fetch origin" >&2
  exit 1
fi

echo "==> Restore Jenkins pipeline files from ${JUNE17_COMMIT}"
git checkout "${JUNE17_COMMIT}" -- \
  paas/jenkins/Jenkinsfile.paas-deploy \
  paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy \
  paas/jenkins/render-loadable-stages.py \
  paas/scripts/lib/create_jenkins_paas_deploy_job.py \
  paas/scripts/lib/install-jenkins-stages-file.sh

echo "==> Install June 17 stages bundle on Jenkins pod"
bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo "==> Push June 17 job wrapper to Jenkins LIVE (--force)"
set -a
source "${ENV_FILE}" 2>/dev/null || true
set +a
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only

echo "==> Disable UI inline job sync (stops reverting wrapper)"
for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
  [[ -f "${f}" ]] || continue
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${f}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${f}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${f}"
  fi
done
PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-1}" ENV_FILE="${ENV_FILE}" \
  bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true

echo "==> Verify Jenkins stages on cluster"
DT_STAGES_MARKER=dt-api-server-svc-20260617 bash "${SCRIPT_DIR}/verify-jenkins-stages-on-cluster.sh" || \
  bash "${SCRIPT_DIR}/verify-jenkins-stages-on-cluster.sh"

echo "==> Verify LIVE Jenkins job (June 17 single-load layout)"
set -a
source "${ENV_FILE}" 2>/dev/null || true
set +a
python3 <<'PY'
import base64, os, sys, urllib.request
from pathlib import Path
vals = {}
for line in Path("paas/frontend/docker-compose.env").read_text().splitlines():
    if "=" in line and not line.strip().startswith("#"):
        k, _, v = line.partition("="); vals[k.strip()] = v.strip().strip('"')
base = (vals.get("JENKINS_PROBE_URL") or "http://192.168.56.129:30090").rstrip("/")
user = os.environ.get("JENKINS_USERNAME") or vals.get("JENKINS_USERNAME")
token = os.environ.get("JENKINS_API_TOKEN") or vals.get("JENKINS_API_TOKEN")
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
live = urllib.request.urlopen(
    urllib.request.Request(f"{base}/job/paas-deploy/config.xml", headers={"Authorization": f"Basic {auth}"}),
    timeout=60,
).read().decode()
if "paas-deploy-stages-load-20260620-cps-split" in live and "load paasStagesP3" in live:
    sys.exit("FAIL: LIVE job still has broken CPS split wrapper")
if "paas-deploy-stages.groovy" not in live and "paasDeployStages" not in live:
    sys.exit("FAIL: LIVE job missing single stages load path")
print("OK: LIVE job uses June 17 style stages load (not CPS split)")
PY

echo ""
echo "=============================================="
echo " OK — rolled back Jenkins pipeline to June 17"
echo ""
echo " 1. Open PaaS:  http://${NODE_IP}:30100"
echo " 2. Trigger NEW paas-deploy build (NOT Replay of #858+)"
echo " 3. Jenkins:    http://${NODE_IP}:30090/job/paas-deploy/"
echo ""
echo " Console should show:"
echo "   paas-deploy-stages-load-20260617"
echo "   Step 1 — Params validation / Check Parameters"
echo "=============================================="
