#!/usr/bin/env bash
# One-shot: align Jenkins paas-deploy with repo Jenkinsfile (fixes Next 16 --no-lint on crane path).
# Run on k3s master after git pull:
#   bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

echo "==> 1. Repo Jenkinsfile must contain crane-next16-202605"
bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh" 2>/dev/null | head -5 || true
if ! grep -qF 'crane-next16-202605' "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"; then
  echo "FAIL: git pull origin main (missing crane-next16-202605 in Jenkinsfile)" >&2
  exit 1
fi

echo "==> 2. Push pipeline to Jenkins from host repo (not stale frontend image)"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force

echo "==> 3. Update PaaS pod Jenkinsfile mount (safe even when sync is disabled)"
if command -v kubectl >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || echo "WARN: ConfigMap sync skipped (no cluster?)"
fi

echo "==> 4. Verify Jenkins job config"
bash "${SCRIPT_DIR}/verify-jenkins-paas-deploy-job-lab.sh"

echo ""
echo "OK — trigger a NEW paas-deploy build. Step 6 console must show:"
echo "  [image] crane-next16-202605: ..."
echo "  (must NOT show: npx next build --no-lint)"
echo ""
echo "If PaaS still overwrites Jenkins with an old file, set in docker-compose.env:"
echo "  JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false"
echo "and run: bash paas/scripts/sync-paas-frontend-env-k8s.sh"
