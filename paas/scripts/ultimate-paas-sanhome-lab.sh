#!/usr/bin/env bash
# One command: fix Jenkinsfile + tokens + Harbor probe → deploy sanhome → wait → verify.
# Run on lab VM as master after k3s is up.
#
#   cd ~/devsecops_paas_miscroservices
#   bash paas/scripts/ultimate-paas-sanhome-lab.sh
#
# Options:
#   PROJECT_NAME=sanhome     (default)
#   ONLY_FIX=1               prep only (no Jenkins build)
#   SKIP_TRIGGER=1           skip deploy trigger
#   SKIP_GITOPS=1            skip gitops tag bump
#   SKIP_K3S_RECOVER=1       skip recover-k3s-api-lab.sh
#   FORCE_SONAR_TOKEN=1      always regenerate Sonar token
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
PROJECT_NAME="${PROJECT_NAME:-sanhome}"
ONLY_FIX="${ONLY_FIX:-0}"
SKIP_TRIGGER="${SKIP_TRIGGER:-0}"
SKIP_GITOPS="${SKIP_GITOPS:-0}"
# ONLY_FIX skips the heavy k3s restart unless you override
SKIP_K3S_RECOVER="${SKIP_K3S_RECOVER:-$([[ "${ONLY_FIX}" == "1" ]] && echo 1 || echo 0)}"
FORCE_SONAR_TOKEN="${FORCE_SONAR_TOKEN:-0}"
NODE_IP="${NODE_IP:-192.168.56.129}"

log() { echo ""; echo "==> $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

[[ -f "${ENV_FILE}" ]] || die "missing ${ENV_FILE}"

upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

log "0. Lab defaults (full security pipeline, no PaaS Jenkins overwrite)"
upsert_env JENKINS_PAAS_FAST_PIPELINE "false"
upsert_env JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
upsert_env HARBOR_FORCE_NODEPORT_PUSH "true"
upsert_env HARBOR_REGISTRY_PUSH ""
export JENKINS_PROBE_URL="${JENKINS_PROBE_URL:-http://${NODE_IP}:30090}"

set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u

if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
  die "JENKINS_USERNAME / JENKINS_API_TOKEN missing in ${ENV_FILE}"
fi

avail_kb="$(awk '/MemAvailable/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
if [[ "${avail_kb}" -gt 0 && "${avail_kb}" -lt 900000 ]]; then
  echo "WARN: low RAM ($(awk '/MemAvailable/ {printf "%.0fMi\n",$2/1024}' /proc/meminfo)) — close other VMs; lab scaled Prometheus/Tekton in recover-k3s-api"
fi

if [[ "${SKIP_K3S_RECOVER}" != "1" ]]; then
  log "1. Kubernetes API + Jenkins DNS (skip with SKIP_K3S_RECOVER=1)"
  bash "${SCRIPT_DIR}/recover-k3s-api-lab.sh" || die "recover-k3s-api-lab.sh failed"
else
  log "1. SKIP_K3S_RECOVER=1"
fi

log "2. Jenkinsfile on disk (patch if git pull did not include sonar.login)"
[[ -f "${JENKINSFILE}" ]] || die "missing ${JENKINSFILE} — git pull or copy from dev machine"

if ! grep -qF 'sonar-scanner-cli6-login-20260607' "${JENKINSFILE}" 2>/dev/null; then
  echo "WARN: Jenkinsfile missing sonar.login marker — applying patch-jenkins-sonar-token-env-lab.sh"
  export JENKINSFILE
  bash "${SCRIPT_DIR}/patch-jenkins-sonar-token-env-lab.sh"
fi
if ! grep -qF 'env-safe-dotenv-loader-20260601' "${JENKINSFILE}" 2>/dev/null; then
  die "Jenkinsfile too old (no env-safe-dotenv). Copy paas/jenkins/Jenkinsfile.paas-deploy from dev machine or git pull."
fi
grep -qE 'sonar\.login|sonar-scanner-cli6-login-20260607' "${JENKINSFILE}" \
  || die "sonar.login still missing after patch — scp Jenkinsfile from Windows repo"

log "3. Sonar token (validate or regenerate)"
SONAR_BASE="${SONAR_BASE_URL:-http://${NODE_IP}:30900}"
VALID="$(curl -sS -m 12 -u "${SONAR_TOKEN:-invalid}:" "${SONAR_BASE%/}/api/authentication/validate" 2>/dev/null || true)"
if [[ "${FORCE_SONAR_TOKEN}" == "1" ]] || ! echo "${VALID}" | grep -q '"valid":true'; then
  bash "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh"
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
else
  echo "OK: existing SONAR_TOKEN validates"
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
fi

log "4. Harbor NodePort healthy (light probe)"
export HARBOR_RECOVER_LIGHT=1
bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || {
  echo "WARN: Harbor probe failed — full recover"
  HARBOR_RECOVER_LIGHT=0 bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || true
}
code="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
  "http://${NODE_IP}:30002/v2/" 2>/dev/null || echo 000)"
[[ "${code}" == "401" || "${code}" == "200" ]] || die "Harbor /v2/ not healthy (HTTP ${code}) — fix Harbor before deploy"

log "5. Jenkins job + ConfigMap (full-document ONLY — never merged-cdata)"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || true
bash "${SCRIPT_DIR}/fix-harbor-jenkins-crane-push-lab.sh" || true
export JENKINSFILE
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
if ! bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"; then
  die "Jenkins job verify failed — copy paas/jenkins/Jenkinsfile.paas-deploy from dev machine, then re-run ONLY_FIX=1"
fi

PROJECT_ID="$(bash "${SCRIPT_DIR}/get-project-id-lab.sh" "${PROJECT_NAME}")"
echo "OK: PROJECT_ID=${PROJECT_ID}"

if [[ "${ONLY_FIX}" == "1" ]]; then
  echo ""
  echo "ONLY_FIX=1 — prep done. Run full deploy (no k3s restart):"
  echo "  SKIP_K3S_RECOVER=1 bash paas/scripts/ultimate-paas-sanhome-lab.sh"
  echo ""
  echo "Or manual:"
  echo "  PROJECT_ID=${PROJECT_ID} python3 paas/scripts/trigger-paas-deploy-lab.py"
  echo "  BUILD_NUMBER=\$(curl -fsS -u \"\$JENKINS_USERNAME:\$JENKINS_API_TOKEN\" \"${JENKINS_PROBE_URL%/}/job/paas-deploy/lastBuild/api/json\" | python3 -c \"import json,sys; print(json.load(sys.stdin)['number'])\") bash paas/scripts/wait-jenkins-paas-build-lab.sh"
  exit 0
fi

if [[ "${SKIP_TRIGGER}" == "1" ]]; then
  echo "SKIP_TRIGGER=1 — done."
  exit 0
fi

log "6. Trigger NEW paas-deploy (not Replay)"
export PROJECT_ID
python3 "${SCRIPT_DIR}/trigger-paas-deploy-lab.py"

BUILD="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_PROBE_URL%/}/job/paas-deploy/lastBuild/api/json" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))")"
[[ -n "${BUILD}" ]] || die "could not read lastBuild number"
echo "Triggered build #${BUILD}"

log "7. Wait for build (up to 2h)"
BUILD_NUMBER="${BUILD}" bash "${SCRIPT_DIR}/wait-jenkins-paas-build-lab.sh" || BUILD_FAILED=1

log "8. Console checks"
CONSOLE="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_PROBE_URL%/}/job/paas-deploy/${BUILD}/consoleText")"
echo "${CONSOLE}" | grep -E 'sonar-scanner-cli6-login|PAAS_STEP_OK step=5|PAAS_STEP_WARN step=5|PAAS_BUILD_COMPLETE|502 Bad Gateway|Not authorized' \
  | tail -20 || true

SONAR_LOG="$(curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_PROBE_URL%/}/job/paas-deploy/${BUILD}/artifact/paas-artifacts/sonar-scanner.log" 2>/dev/null || true)"
if echo "${SONAR_LOG}" | grep -qi 'Not authorized'; then
  die "Build #${BUILD} Sonar still Not authorized — run FORCE_SONAR_TOKEN=1 $0"
fi
if echo "${SONAR_LOG}" | grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS'; then
  echo "OK: Sonar analysis succeeded on #${BUILD}"
elif echo "${CONSOLE}" | grep -q 'PAAS_STEP_OK step=5'; then
  echo "OK: PAAS_STEP_OK step=5 on #${BUILD}"
else
  echo "WARN: Sonar may have failed — see artifact sonar-scanner.log"
fi

if [[ "${BUILD_FAILED:-0}" == "1" ]]; then
  die "Build #${BUILD} did not SUCCESS"
fi

log "9. Verify security chain"
BUILD_NUMBER="${BUILD}" PROJECT_ID="${PROJECT_ID}" PROJECT_NAME="${PROJECT_NAME}" \
  bash "${SCRIPT_DIR}/verify-security-pipeline-lab.sh" || VERIFY_FAIL=1

TAG="${BUILD}"
REGISTRY="${HARBOR_REGISTRY:-${NODE_IP}:30002}"
IMAGE="${REGISTRY}/paas/${PROJECT_NAME}:${TAG}"
if command -v crane >/dev/null 2>&1; then
  if crane digest "${IMAGE}" >/dev/null 2>&1; then
    echo "OK: Harbor has ${IMAGE}"
  else
    echo "WARN: ${IMAGE} not in Harbor — GitOps will ImagePullBackOff if you promote :${TAG}"
    SKIP_GITOPS=1
  fi
fi

if [[ "${SKIP_GITOPS}" != "1" && "${VERIFY_FAIL:-0}" != "1" ]]; then
  log "10. GitOps tag :${TAG} (optional)"
  GITOPS_DIR="${GITOPS_DIR:-${HOME}/gitops}"
  if [[ -d "${GITOPS_DIR}/apps/${PROJECT_NAME}" ]]; then
    python3 - "${GITOPS_DIR}" "${PROJECT_NAME}" "${REGISTRY}" "${TAG}" <<'PY'
import sys, yaml
from pathlib import Path
root, name, repo, tag = sys.argv[1:5]
p = Path(root) / "apps" / name / "values.yaml"
d = yaml.safe_load(p.read_text()) or {}
for slot in ("blue", "green"):
    d.setdefault(slot, {}).setdefault("image", {})["tag"] = tag
    d[slot]["image"]["repository"] = repo + "/paas/" + name
d["image"] = {"repository": repo + "/paas/" + name, "tag": tag, "digest": "", "pullPolicy": "IfNotPresent"}
p.write_text(yaml.safe_dump(d, default_flow_style=False, sort_keys=False))
print("OK: wrote", p)
PY
    (cd "${GITOPS_DIR}" && git add "apps/${PROJECT_NAME}/values.yaml" \
      && git commit -m "chore(gitops): ${PROJECT_NAME} deploy :${TAG}" || true)
    bash "${SCRIPT_DIR}/push-gitops-lab.sh" || echo "WARN: gitops push failed"
    # shellcheck disable=SC1091
    [[ -f "${SCRIPT_DIR}/lib/argo-sync-lab.sh" ]] && source "${SCRIPT_DIR}/lib/argo-sync-lab.sh" \
      && argo_sync_app_lab "paas-${PROJECT_NAME}" || true
  else
    echo "WARN: no ${GITOPS_DIR}/apps/${PROJECT_NAME} — SKIP_GITOPS or set GITOPS_DIR"
  fi
fi

log "DONE"
echo "  Build:    #${BUILD} SUCCESS"
echo "  Image:    ${IMAGE}"
echo "  UI:       http://${NODE_IP}:30100 → ${PROJECT_NAME} → Security"
echo "  Jenkins:  ${JENKINS_PROBE_URL}/job/paas-deploy/${BUILD}/console"
if [[ "${VERIFY_FAIL:-0}" == "1" ]]; then
  echo "  Verify had warnings — re-run:"
  echo "    BUILD_NUMBER=${BUILD} PROJECT_ID=${PROJECT_ID} PROJECT_NAME=${PROJECT_NAME} bash paas/scripts/verify-security-pipeline-lab.sh"
  exit 1
fi
