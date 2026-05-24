#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-$HOME/devsecops_paas_miscroservices}"
NS=cicd

echo "This downloads plugins into the PVC (3–10 min). Do not restart Jenkins during download."
bash "${REPO}/paas/scripts/install-jenkins-plugins-lab.sh"

echo ""
echo "Then create the job:"
echo "  unset JENKINS_BASE_URL JENKINS_URL"
echo "  python3 ${REPO}/paas/scripts/create_jenkins_paas_deploy_job.py --minimal"
