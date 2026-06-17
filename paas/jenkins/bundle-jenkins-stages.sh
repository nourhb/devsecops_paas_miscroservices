#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
MAIN="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
STAGES="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy"

if [[ ! -f "${MAIN}" || ! -f "${STAGES}" ]]; then
  echo "ERROR: missing main Jenkinsfile or stages file" >&2
  exit 1
fi

printf '%s\n' '// paas-deploy-stages-bundled-helpers+stages-20260617'
awk '/^def agentLabel = / { exit } { print }' "${MAIN}"
cat "${STAGES}"
