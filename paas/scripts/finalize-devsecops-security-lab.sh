#!/usr/bin/env bash
#
# Ultimate lab fix: Cosign keys, Jenkins Step 9, frontend Security UI, sign latest image, verify API.
# Run once on the VM after git pull — do not Ctrl+C.
#
#   cd ~/devsecops_paas_miscroservices && git pull
#   bash paas/scripts/finalize-devsecops-security-lab.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PROJECT_ID="${PROJECT_ID:-a953adb2-4a4b-4412-bbac-0fa9e4b181e3}"
SKIP_FRONTEND_REBUILD="${SKIP_FRONTEND_REBUILD:-0}"
TRIGGER_DEPLOY="${TRIGGER_DEPLOY:-0}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "========== $* =========="; }

cd "${REPO_ROOT}"

step "1/8 — Kyverno + API tokens (Sonar, Dependency-Track)"
bash "${SCRIPT_DIR}/apply-kyverno-policies-lab.sh" || true
REGENERATE_SONAR_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh" || true
REGENERATE_DT_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-dependency-track-api-key-lab.sh" || true

step "2/8 — Sync Cosign keys (env, Jenkins pod, Kyverno, frontend env)"
SYNC_JENKINS=1 SYNC_FRONTEND=1 bash "${SCRIPT_DIR}/sync-cosign-keys-lab.sh"

step "3/8 — Mount cosign.pub + Harbor docker auth into frontend"
bash "${SCRIPT_DIR}/mount-cosign-pub-frontend-lab.sh"
bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh"

if [[ "${SKIP_FRONTEND_REBUILD}" != "1" ]]; then
  step "4/8 — Rebuild frontend image (bundled cosign + Harbor-aware verify) — ~6 min"
  bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"
else
  step "4/8 — SKIP_FRONTEND_REBUILD=1 (API may stay cosignSigned=false until you rebuild once)"
  bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}" || true
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
  bash "${SCRIPT_DIR}/mount-cosign-pub-frontend-lab.sh"
  bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh"
fi

step "5/8 — Sign latest successful Jenkins artifact image"
bash "${SCRIPT_DIR}/sign-latest-jenkins-paas-image-lab.sh" lastBuild

step "6/8 — Security API smoke test"
LOGIN_JSON='{"email":"nourhb58@gmail.com","password":"YourNewPassword123"}'
COOKIE_JAR="/tmp/paas-finalize-cookies.txt"
rm -f "${COOKIE_JAR}"
if curl -sf "http://127.0.0.1:30100/api/health" >/dev/null 2>&1; then
  PAAS_URL="http://127.0.0.1:30100"
else
  PAAS_URL="http://192.168.56.129:30100"
fi
curl -sf -c "${COOKIE_JAR}" -X POST "${PAAS_URL}/api/auth/login" \
  -H "Content-Type: application/json" -d "${LOGIN_JSON}" >/dev/null \
  || die "Login failed at ${PAAS_URL} — run bash paas/scripts/seed-admin-user-lab.sh"

SEC_JSON="$(curl -sf -b "${COOKIE_JAR}" "${PAAS_URL}/api/security/${PROJECT_ID}")"

python3 - "${SEC_JSON}" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
signed = d.get("cosignSigned")
score = d.get("securityScore")
ref = (d.get("imageSecurity") or {}).get("imageRef", "")
gate = d.get("qualityGateStatus")
print(f"  imageRef:       {ref}")
print(f"  cosignSigned:   {signed}")
print(f"  securityScore:  {score}")
print(f"  qualityGate:    {gate}")
if not signed:
    raise SystemExit("FAIL: cosignSigned is still false — check kubectl logs -n paas deploy/frontend --tail=50")
print("OK: Security API reports cosignSigned=true")
PY

if [[ "${TRIGGER_DEPLOY}" == "1" ]]; then
  step "7/8 — Trigger new Jenkins deploy (Step 9 should auto-sign)"
  PROJECT_ID="${PROJECT_ID}" python3 "${SCRIPT_DIR}/trigger-paas-deploy-lab.py"
  echo "Wait for SUCCESS, then: bash paas/scripts/sign-latest-jenkins-paas-image-lab.sh lastBuild"
else
  step "7/8 — Skip new deploy (set TRIGGER_DEPLOY=1 to trigger build #next)"
fi

step "8/8 — Done"
cat <<EOF

DevSecOps security lab is configured.

  Security UI:  ${PAAS_URL}/security/${PROJECT_ID}
  Jenkins:      http://127.0.0.1:30090/job/paas-deploy/

After each future deploy (if Step 9 ever fails):
  bash paas/scripts/sign-latest-jenkins-paas-image-lab.sh lastBuild

Full re-run anytime:
  bash paas/scripts/finalize-devsecops-security-lab.sh

Fast re-sync without rebuild (~2 min):
  SKIP_FRONTEND_REBUILD=1 bash paas/scripts/finalize-devsecops-security-lab.sh
EOF
