#!/usr/bin/env bash
#
# One-shot lab fix: Sonar/DT env, Jenkins full pipeline, Cosign keys, Harbor Trivy in UI, sign all deployed images.
#
#   cd ~/devsecops_paas_miscroservices && git pull
#   bash paas/scripts/fix-security-all-projects-lab.sh
#
# Rebuild frontend (~6 min) so Harbor Trivy code is in the pod:
#   REBUILD_FRONTEND=1 bash paas/scripts/fix-security-all-projects-lab.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
REBUILD_FRONTEND="${REBUILD_FRONTEND:-0}"
SIGN_IMAGES="${SIGN_IMAGES:-1}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo ""; echo "========== $* =========="; }

cd "${REPO_ROOT}"
[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}"

step "1/6 — Wire Sonar, Dependency-Track, Kyverno, Cosign keys, JENKINS_PAAS_FAST_PIPELINE=false"
SKIP_INTEGRATION_DIAGNOSE=1 bash "${SCRIPT_DIR}/setup-security-lab.sh"

step "2/6 — Jenkins paas-deploy job (Sonar/DT/Cosign parameters + latest Jenkinsfile)"
bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true
SYNC_JENKINS=1 SYNC_FRONTEND=0 bash "${SCRIPT_DIR}/sync-cosign-keys-lab.sh"

step "3/6 — Frontend: cosign.pub mount + Harbor docker auth for verify"
bash "${SCRIPT_DIR}/mount-cosign-pub-frontend-lab.sh"
bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh"

if [[ "${REBUILD_FRONTEND}" == "1" ]]; then
  step "4/6 — Rebuild frontend (Harbor Trivy + cosign verify in API)"
  bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"
else
  step "4/6 — Sync env to frontend pod (skip rebuild; set REBUILD_FRONTEND=1 if Trivy still 'fetch failed')"
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
  bash "${SCRIPT_DIR}/mount-cosign-pub-frontend-lab.sh"
  bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh"
fi

step "5/6 — Verify integrations (Sonar token, Jenkins params, last build)"
AUTO_FIX=1 bash "${SCRIPT_DIR}/verify-security-pipeline-lab.sh" || true

if [[ "${SIGN_IMAGES}" == "1" ]]; then
  step "6/6 — Cosign-sign all images currently deployed"
  bash "${SCRIPT_DIR}/sign-all-deployed-paas-images-lab.sh"
else
  step "6/6 — SKIP sign (SIGN_IMAGES=0)"
fi

cat <<'EOF'

Security lab configuration applied.

What should work now (after frontend rebuild if you set REBUILD_FRONTEND=1):
  • Trivy counts — Harbor vulnerability API (no standalone :30954 /scan server required)
  • Cosign signed — images signed in step 6; new builds sign in Jenkins Step 9 when keys are synced
  • Sonar quality gate — still UNKNOWN until each project runs a full deploy with Step 5
  • Dependency-Track — still empty until Step 4 uploads SBOM on a full deploy

Populate Sonar + Dependency-Track per project (one at a time; Jenkins queue is shared):
  1. Confirm: grep JENKINS_PAAS_FAST_PIPELINE paas/frontend/docker-compose.env  → false
  2. PaaS UI → project → Deploy   OR:
     export PROJECT_ID=<uuid>
     python3 paas/scripts/trigger-paas-deploy-lab.py
  3. Wait Jenkins SUCCESS; refresh Security page

Quick check:
  bash paas/scripts/verify-security-pipeline-lab.sh
  bash paas/scripts/sign-all-deployed-paas-images-lab.sh

EOF
