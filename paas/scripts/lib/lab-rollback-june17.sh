#!/usr/bin/env bash
# Roll back Jenkins pipeline to last known-good lab state:
#   17 June 2026 ~14:38 — Jenkins build #756 DEPLOYED (git commit bb1fef3)
# Everything after 390fb61 (18 June Blue Ocean split) broke the pipeline.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JUNE17_COMMIT="${JUNE17_COMMIT:-bb1fef3}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " Roll back to June 17 2026 (build #756 era)"
echo " Target commit: ${JUNE17_COMMIT}"
echo "=============================================="

if [[ "${LAB_ROLLBACK_CONFIRM:-}" != "1" ]]; then
  echo ""
  echo "This restores the Jenkins load() layout that worked on 17 June."
  echo "Run with:"
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
  paas/jenkins/render-loadable-stages.py \
  paas/scripts/lib/create_jenkins_paas_deploy_job.py

echo "==> Install June 17 stages + sync Jenkins job"
SKIP_FRONTEND_REBUILD=true LAB_DT_SKIP_HEAL=true \
  bash "${SCRIPT_DIR}/sync-jenkins-pipeline-from-repo.sh"

echo "==> Frontend recovery image (skip long rebuild)"
bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh" || true

echo "==> Postgres / DB connectivity"
PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true

echo ""
echo "==> Verify Jenkins stages on cluster"
bash "${SCRIPT_DIR}/verify-jenkins-stages-on-cluster.sh"

echo ""
echo "=============================================="
echo " OK — rolled back Jenkins pipeline to June 17"
echo ""
echo " 1. Open PaaS:  http://${NODE_IP}:30100"
echo " 2. Deploy your project (new build, NOT Replay of #770+)"
echo " 3. Jenkins:    http://${NODE_IP}:30090/job/paas-deploy/"
echo ""
echo " Console should show:"
echo "   paas-deploy-stages-load-20260617 (Steps 1-12 via load inside node"
echo " Then Step 1 — Params validation"
echo "=============================================="
