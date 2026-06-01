#!/usr/bin/env bash
# Remove Jenkins node_modules snapshot cache for one PaaS project (fixes stuck cp -a on huge trees).
set -euo pipefail

PROJECT_ID="${1:-}"
JENKINS_HOME="${JENKINS_HOME:-/var/jenkins_home}"

if [[ -z "${PROJECT_ID}" ]]; then
  echo "Usage: bash paas/scripts/clear-nm-snap-project-lab.sh <project-uuid>" >&2
  echo "  Or: bash paas/scripts/clear-nm-snap-project-lab.sh sanhome  # resolves id from Postgres" >&2
  exit 1
fi

if [[ ! "${PROJECT_ID}" =~ ^[0-9a-f-]{36}$ ]]; then
  NAME="${PROJECT_ID}"
  PROJECT_ID="$(kubectl exec -n paas deploy/postgres -- psql -U postgres -d paas -tAc \
    "SELECT id FROM \"Project\" WHERE \"projectName\" = '${NAME}' AND \"deletedAt\" IS NULL LIMIT 1;" 2>/dev/null | tr -d ' \r\n')"
  [[ -n "${PROJECT_ID}" ]] || { echo "ERROR: unknown project ${NAME}" >&2; exit 1; }
  echo "Project ${NAME} → ${PROJECT_ID}"
fi

TARGET="${JENKINS_HOME}/.jenkins-paas-cache/nm-snap/${PROJECT_ID}"
if kubectl get pod -n jenkins -l app=jenkins >/dev/null 2>&1 || kubectl get pod -n cicd -l app=jenkins >/dev/null 2>&1; then
  NS="jenkins"
  kubectl get pod -n cicd -l app=jenkins >/dev/null 2>&1 && NS="cicd"
  POD="$(kubectl get pod -n "${NS}" -l app=jenkins -o jsonpath='{.items[0].metadata.name}')"
  echo "==> Remove nm-snap in Jenkins pod ${NS}/${POD}"
  kubectl exec -n "${NS}" "${POD}" -- rm -rf "${TARGET}" 2>/dev/null || true
else
  echo "==> Remove on host: ${TARGET}"
  rm -rf "${TARGET}" 2>/dev/null || true
fi
echo "OK. Next deploy runs npm ci instead of restoring a huge snapshot."
