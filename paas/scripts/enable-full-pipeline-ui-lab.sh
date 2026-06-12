#!/usr/bin/env bash
# One-shot: full security pipeline + DT/Sonar keys + parallel Jenkins + PaaS frontend.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
EXECUTORS="${JENKINS_NUM_EXECUTORS:-8}"

upsert() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" 2>/dev/null || \
      sed -i '' "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

cd "${REPO_ROOT}"
git pull origin main

echo "==> Postgres (login requires postgres.paas.svc.cluster.local:5432)"
if ! bash "${SCRIPT_DIR}/check-paas-lab-health.sh" 2>/dev/null | grep -q "OK: postgres"; then
  echo "WARN: Postgres not ready — recovering before frontend redeploy"
  bash "${SCRIPT_DIR}/deploy-paas-postgres-lab.sh" || bash "${SCRIPT_DIR}/recover-paas-after-k3s-restart.sh"
else
  echo "OK: Postgres already running"
fi

echo "==> Session stability (HTTP lab — stop random logouts)"
upsert APP_BASE_URL "http://192.168.56.129:30100"
upsert SESSION_COOKIE_SECURE "false"
upsert JWT_EXPIRES_IN "24h"

echo "==> Full pipeline (no fast skip — force false in env + Jenkins job)"
upsert JENKINS_PAAS_FAST_PIPELINE "false"
upsert PAAS_ALLOW_FAST_PIPELINE "false"
# Fix common lab mistake: true left in env from older scripts
sed -i 's/^JENKINS_PAAS_FAST_PIPELINE=true/JENKINS_PAAS_FAST_PIPELINE=false/' "${ENV_FILE}" 2>/dev/null || \
  sed -i '' 's/^JENKINS_PAAS_FAST_PIPELINE=true/JENKINS_PAAS_FAST_PIPELINE=false/' "${ENV_FILE}" 2>/dev/null || true
sed -i 's/^PAAS_ALLOW_FAST_PIPELINE=true/PAAS_ALLOW_FAST_PIPELINE=false/' "${ENV_FILE}" 2>/dev/null || \
  sed -i '' 's/^PAAS_ALLOW_FAST_PIPELINE=true/PAAS_ALLOW_FAST_PIPELINE=false/' "${ENV_FILE}" 2>/dev/null || true
upsert JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "true"
upsert JENKINS_NUM_EXECUTORS "${EXECUTORS}"
upsert JENKINS_PAAS_CONCURRENT_BUILDS "true"
upsert PAAS_MAX_CONCURRENT_JENKINS_DEPLOYS "${EXECUTORS}"

echo "==> Sonar token (fixes Step 5 token validate: valid=false)"
if [[ -x "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh" || {
    echo "WARN: Sonar token regen failed — run: bash paas/scripts/regenerate-sonar-token-lab.sh"
  }
fi

echo "==> Dependency-Track API key (fixes DEPENDENCY_TRACK_API_KEY=MISSING)"
if [[ -x "${SCRIPT_DIR}/regenerate-dependency-track-api-key-lab.sh" ]]; then
  REGENERATE_DT_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-dependency-track-api-key-lab.sh" || {
    echo "WARN: Could not auto-generate DT API key — run: bash paas/scripts/regenerate-dependency-track-api-key-lab.sh"
  }
else
  echo "WARN: regenerate-dependency-track-api-key-lab.sh missing — git pull again"
fi

echo "==> Sync Jenkinsfile ConfigMap"
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh"

echo "==> Jenkins job: SONAR_*, DEPENDENCY_TRACK_*, concurrent builds"
if [[ -x "${SCRIPT_DIR}/ensure-jenkins-security-params-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/ensure-jenkins-security-params-lab.sh"
else
  bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh"
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
fi

export JENKINS_NUM_EXECUTORS="${EXECUTORS}"
export JENKINS_PAAS_CONCURRENT_BUILDS=true
if [[ -x "${SCRIPT_DIR}/scale-jenkins-concurrency-lab.sh" ]]; then
  SCALE_JENKINS_SKIP_FRONTEND=1 bash "${SCRIPT_DIR}/scale-jenkins-concurrency-lab.sh"
else
  echo "==> Jenkins executors (inline — scale-jenkins-concurrency-lab.sh not found yet)"
  python3 "${SCRIPT_DIR}/jenkins-configure-lab.py" || true
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
fi

echo "==> Redeploy PaaS frontend (env + Jenkinsfile mount)"
bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"

echo ""
echo "==> Verify pod security env"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a
for v in SONAR_TOKEN DEPENDENCY_TRACK_API_KEY JENKINS_PAAS_FAST_PIPELINE PAAS_ALLOW_FAST_PIPELINE PAAS_MAX_CONCURRENT_JENKINS_DEPLOYS; do
  val="$(kubectl exec -n paas deploy/frontend -- printenv "${v}" 2>/dev/null || true)"
  if [[ -n "${val}" ]]; then
    echo "  ${v}=${val}"
  else
    echo "  ${v}=MISSING"
  fi
done
if [[ "$(kubectl exec -n paas deploy/frontend -- printenv JENKINS_PAAS_FAST_PIPELINE 2>/dev/null || true)" == "true" ]]; then
  echo "ERROR: frontend pod still has JENKINS_PAAS_FAST_PIPELINE=true — fix ${ENV_FILE} and re-run this script" >&2
  exit 1
fi

echo ""
echo "==> Boot auto-recover (run ONCE with sudo — fixes login after PC restart)"
if [[ "$(id -u)" -eq 0 ]]; then
  bash "${SCRIPT_DIR}/install-paas-autostart-lab.sh"
else
  echo "  sudo bash paas/scripts/install-paas-autostart-lab.sh"
  echo "  (Then every reboot: Postgres + frontend recover automatically in ~2–5 min)"
fi

echo ""
echo "OK. From PaaS UI only:"
echo "  1. Edit project → Application environment (.env) → Save"
echo "  2. Deploy (Steps 4–5 SCA/SAST; up to ${EXECUTORS} projects in parallel)"
echo ""
echo "More executors: JENKINS_NUM_EXECUTORS=12 bash paas/scripts/enable-full-pipeline-ui-lab.sh"
