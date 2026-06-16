#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
MARKER="${JENKINSFILE_MARKER:-nginx-conf-writefile-20260611}"
RAW_URL="${JENKINSFILE_RAW_URL:-https://raw.githubusercontent.com/nourhb/devsecops_paas_miscroservices/main/paas/jenkins/Jenkinsfile.paas-deploy}"
die() { echo "ERROR: $*" >&2; exit 1; }
has_marker() {
  local f="$1"
  [[ -f "${f}" ]] && grep -qF "${MARKER}" "${f}" && grep -qF 'writeNginxPaasDefaultConf' "${f}"
}
if has_marker "${JENKINSFILE}"; then
  echo "${JENKINSFILE}"
  exit 0
fi
echo "WARN: ${JENKINSFILE} missing ${MARKER} — git pull" >&2
git -C "${REPO_ROOT}" pull --ff-only 2>/dev/null || true
if has_marker "${JENKINSFILE}"; then
  echo "${JENKINSFILE}"
  exit 0
fi
FRESH="/tmp/Jenkinsfile.paas-deploy.${MARKER}.lab"
echo "WARN: fetching Jenkinsfile from ${RAW_URL}" >&2
curl -fsSL --retry 3 --connect-timeout 30 "${RAW_URL}" -o "${FRESH}" || die "curl failed for ${RAW_URL}"
has_marker "${FRESH}" || die "Downloaded Jenkinsfile still missing ${MARKER} — push fixes to GitHub or scp Jenkinsfile to lab"
echo "${FRESH}"
