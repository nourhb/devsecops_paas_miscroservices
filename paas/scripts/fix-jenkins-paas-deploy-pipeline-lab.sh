#!/usr/bin/env bash
# One-shot: align Jenkins paas-deploy with repo Jenkinsfile (fixes Next 16 --no-lint on crane path).
# Run on k3s master after git pull:
#   bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
JENKINSFILE_TO_PUSH="${JENKINSFILE}"
echo "==> 1. Resolve Jenkinsfile with crane-next16-202605"
if ! grep -qF 'crane-next16-202605' "${JENKINSFILE}" 2>/dev/null; then
  echo "WARN: local repo missing fix — fetching from GitHub raw (main)"
  FRESH="/tmp/Jenkinsfile.paas-deploy.crane-next16"
  curl -fsSL --retry 3 --connect-timeout 30 \
    "https://raw.githubusercontent.com/nourhb/devsecops_paas_miscroservices/main/paas/jenkins/Jenkinsfile.paas-deploy" \
    -o "${FRESH}"
  if ! grep -qF 'crane-next16-202605' "${FRESH}"; then
    echo "FAIL: downloaded Jenkinsfile still missing crane-next16-202605" >&2
    exit 1
  fi
  JENKINSFILE_TO_PUSH="${FRESH}"
else
  git -C "${REPO_ROOT}" pull --ff-only origin main 2>/dev/null || true
fi

echo "==> 2. Push pipeline to Jenkins (host file, not PaaS bundled image)"
export JENKINSFILE="${JENKINSFILE_TO_PUSH}"
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
