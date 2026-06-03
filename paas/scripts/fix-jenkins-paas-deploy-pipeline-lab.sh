#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
JENKINSFILE_TO_PUSH="${JENKINSFILE}"
echo "==> 1. Resolve Jenkinsfile with monorepo-app-root-20260531"
if ! grep -qF 'monorepo-app-root-20260531' "${JENKINSFILE}" 2>/dev/null; then
  echo "WARN: local repo missing monorepo fix — fetching from GitHub raw (main)"
  FRESH="/tmp/Jenkinsfile.paas-deploy.monorepo-fix"
  curl -fsSL --retry 3 --connect-timeout 30 \
    "https://raw.githubusercontent.com/nourhb/devsecops_paas_miscroservices/main/paas/jenkins/Jenkinsfile.paas-deploy" \
    -o "${FRESH}"
  if ! grep -qF 'monorepo-app-root-20260531' "${FRESH}"; then
    echo "FAIL: downloaded Jenkinsfile still missing monorepo-app-root-20260531" >&2
    exit 1
  fi
  JENKINSFILE_TO_PUSH="${FRESH}"
else
  git -C "${REPO_ROOT}" pull --ff-only origin main 2>/dev/null || true
fi
if ! grep -qF 'crane-next16-202605-j48300-split' "${JENKINSFILE_TO_PUSH}" 2>/dev/null; then
  echo "FAIL: Jenkinsfile missing crane-next16-202605-j48300-split" >&2
  exit 1
fi
if grep -qF '--cmd=-c' "${JENKINSFILE_TO_PUSH}" 2>/dev/null; then
  echo "FAIL: Jenkinsfile still has broken crane mutate (--cmd=-c). git pull origin main or copy fixed Jenkinsfile from dev machine." >&2
  exit 1
fi
if ! grep -qF 'entrypoint=/app/start-paas.sh' "${JENKINSFILE_TO_PUSH}" 2>/dev/null; then
  echo "FAIL: Jenkinsfile missing start-paas.sh mutate fix (entrypoint=/app/start-paas.sh)" >&2
  exit 1
fi
if ! grep -qF 'env-safe-dotenv-loader-20260601' "${JENKINSFILE_TO_PUSH}" 2>/dev/null; then
  echo "FAIL: Jenkinsfile missing env-safe-dotenv-loader-20260601 (EMAIL_PASS / .env spaces fix)." >&2
  echo "  Push latest code from your dev machine, then on VM: git pull && bash paas/scripts/apply-jenkins-env-dotenv-fix-lab.sh" >&2
  exit 1
fi
if ! grep -qF 'cosign-digest-crane-bin-20260602' "${JENKINSFILE_TO_PUSH}" 2>/dev/null; then
  echo "FAIL: Jenkinsfile missing cosign-digest-crane-bin-20260602 (Kyverno needs digest cosign sign)." >&2
  echo "  git pull origin main && bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh" >&2
  exit 1
fi

echo "==> 2. Wait for Jenkins API (pod may be Ready before :30090 accepts connections)"
JENKINS_WAIT_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
for i in $(seq 1 60); do
  if curl -fsS --connect-timeout 5 "${JENKINS_WAIT_URL}/api/json" >/dev/null 2>&1; then
    echo "OK: Jenkins API at ${JENKINS_WAIT_URL}"
    break
  fi
  echo "waiting for Jenkins (${i}/60)…"
  sleep 5
  if [[ "${i}" -eq 60 ]]; then
    echo "FAIL: Jenkins not up at ${JENKINS_WAIT_URL} — kubectl get pods -n cicd -l app=jenkins" >&2
    exit 1
  fi
done

echo "==> 3. Harbor in-cluster push (avoids nginx 502 on crane blob upload)"
if command -v kubectl >/dev/null 2>&1 && kubectl get ns harbor >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/fix-harbor-jenkins-crane-push-lab.sh" || echo "WARN: fix-harbor-jenkins-crane-push-lab.sh failed"
  bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
else
  echo "WARN: no Harbor namespace — skip HARBOR_REGISTRY_PUSH wiring"
fi

echo "==> 3b. Push pipeline + full job parameters (SONAR_*, DEPENDENCY_TRACK_*, HARBOR_REGISTRY_PUSH) to Jenkins"
export JENKINSFILE="${JENKINSFILE_TO_PUSH}"
if ! grep -qF 'harbor-nodeport-push-20260605' "${JENKINSFILE}" 2>/dev/null; then
  echo "WARN: Jenkinsfile missing harbor-nodeport-push-20260605 — git pull origin main"
fi
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo "==> 4. Update PaaS pod Jenkinsfile mount (safe even when sync is disabled)"
if command -v kubectl >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || echo "WARN: ConfigMap sync skipped (no cluster?)"
  echo "If builds fail on '. ./.env' / EMAIL_PASS spaces: Jenkinsfile now loads .env via Node (no secret echo). Re-trigger deploy after sync."
fi

echo "==> 5. Patch Jenkins JAVA_OPTS (JENKINS-48300 durable-task heartbeat)"
JENKINS_NS="${JENKINS_NS:-cicd}"
JENKINS_DEPLOY="${JENKINS_DEPLOY:-jenkins}"
JAVA_HEARTBEAT="-Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=86400"
if kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" >/dev/null 2>&1; then
  CUR="$(kubectl get deployment "${JENKINS_DEPLOY}" -n "${JENKINS_NS}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="JAVA_OPTS")].value}' 2>/dev/null || true)"
  if [[ "${CUR}" != *HEARTBEAT_CHECK_INTERVAL* ]]; then
    NEW_OPTS="${CUR:--Xms256m -Xmx768m -Djenkins.install.runSetupWizard=false} ${JAVA_HEARTBEAT}"
    kubectl set env deployment/"${JENKINS_DEPLOY}" -n "${JENKINS_NS}" JAVA_OPTS="${NEW_OPTS}"
    kubectl rollout status deployment/"${JENKINS_DEPLOY}" -n "${JENKINS_NS}" --timeout=300s
    echo "OK: Jenkins restarted with HEARTBEAT_CHECK_INTERVAL=86400"
  else
    echo "OK: Jenkins JAVA_OPTS already has HEARTBEAT_CHECK_INTERVAL"
  fi
else
  echo "WARN: no deployment/${JENKINS_DEPLOY} in ${JENKINS_NS} — apply jenkins-cicd-pvc.yaml or set JAVA_OPTS manually"
fi

echo "==> 6. Stop PaaS from overwriting Jenkins with an old bundled Jenkinsfile"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
upsert_inline_sync() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || return 0
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}
upsert_inline_sync JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true

echo "==> 7. Verify Jenkins job config"
if ! bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"; then
  echo "WARN: verify reported a problem — if step 3 POST config.xml was 200, you may still trigger a new build."
  echo "      Check: curl -sS -u USER:TOKEN ${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}/job/paas-deploy/config.xml | grep -E 'crane-next16|Step 6a|foreground cmd'"
fi

echo ""
echo "OK — trigger a NEW build (not Rebuild). Console must show:"
echo "  marker cosign-digest-crane-bin-20260602"
echo "  PAAS_IMAGE_DIGEST=... after crane mutate"
echo "  [cosign] signing digest ... then [cosign] signing tag ..."
echo "  marker next-config-build-env-20260531"
echo "  [env] Wrote N variable(s) ... NEXT_PUBLIC_FIREBASE_*"
echo "  [env] patched next.config.ts with env"
echo "  [env] verify OK: Firebase ... in .next output"
echo ""
echo "If Step 6 still runs npm ci for 15+ min: set JENKINS_PAAS_FAST_PIPELINE=false in docker-compose.env"
echo "  so Step 3 does npm ci + next build (Step 6 only packages .next/standalone)."
echo ""
echo "If PaaS still overwrites Jenkins with an old file, set in docker-compose.env:"
echo "  JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false"
echo "and run: bash paas/scripts/sync-paas-frontend-env-k8s.sh"
