#!/usr/bin/env bash
# One-shot repair: Kyverno policies, Sonar token, Dependency-Track API key, Jenkins params, frontend env.
#
#   cd ~/devsecops_paas_miscroservices && git pull
#   bash paas/scripts/fix-security-checks-lab.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

cd "${REPO_ROOT}"

echo "=== 0. Fix SPA/Angular Step 6 uri (Jenkins must have nginx-conf-writefile-20260611) ==="
bash "${SCRIPT_DIR}/apply-nginx-uri-fix-lab.sh"

echo "=== 1. Kyverno (install/repair + apply policies) ==="
bash "${SCRIPT_DIR}/apply-kyverno-policies-lab.sh"

echo "=== 2. Sonar token (regenerate if invalid) ==="
REGENERATE_SONAR_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh" || true

echo "=== 3. Dependency-Track API key ==="
REGENERATE_DT_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-dependency-track-api-key-lab.sh" || true

echo "=== 4. Cosign + Harbor + Jenkins job (full security params) ==="
upsert_env() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}
upsert_env JENKINS_PAAS_FAST_PIPELINE "false"
upsert_env JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
upsert_env KYVERNO_POLICIES_ENABLED "true"
SYNC_JENKINS=1 SYNC_FRONTEND=1 bash "${SCRIPT_DIR}/sync-cosign-keys-lab.sh"

echo "=== 5. Jenkins pipeline from repo ==="
bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh" || \
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full

echo "=== 6. Frontend env secret ==="
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo ""
echo "=== Verify ==="
kubectl get clusterpolicies.kyverno.io require-signed-images require-non-root 2>/dev/null || true
bash "${SCRIPT_DIR}/diagnose-sonar-jenkins-lab.sh" || true

echo ""
echo "OK. Trigger a NEW deploy (not Replay):"
echo "  PROJECT_ID=<uuid> python3 paas/scripts/trigger-paas-deploy-lab.py"
echo "Then refresh PaaS → Security (Kyverno + Cosign + SBOM + Sonar)."
