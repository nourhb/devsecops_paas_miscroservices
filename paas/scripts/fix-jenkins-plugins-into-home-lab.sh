#!/usr/bin/env bash
# Install Pipeline plugins into /var/jenkins_home/plugins (PVC) and restart Jenkins.
# Use when ref/ copy failed or create_jenkins_paas_deploy_job.py says plugins missing.
set -euo pipefail

REPO="${REPO:-$HOME/devsecops_paas_miscroservices}"
NS=cicd

echo "This downloads plugins into the PVC (3–10 min). Do not restart Jenkins during download."
bash "${REPO}/paas/scripts/install-jenkins-plugins-lab.sh"

echo ""
echo "Then create the job:"
echo "  unset JENKINS_BASE_URL JENKINS_URL"
echo "  python3 ${REPO}/paas/scripts/create_jenkins_paas_deploy_job.py --minimal"
