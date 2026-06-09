#!/usr/bin/env bash
# Patch Step 5 Sonar in Jenkinsfile (JAVA_HOME + console log + returnStatus). Run on lab VM.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${JENKINSFILE:-${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy}"
MARKER="paas-artifacts/sonar-scanner.log"

[[ -f "${JENKINSFILE}" ]] || { echo "ERROR: missing ${JENKINSFILE}" >&2; exit 1; }

if grep -qF "${MARKER}" "${JENKINSFILE}"; then
  echo "OK: Jenkinsfile already has Sonar Step 5 fix (${MARKER})"
else
  echo "==> Patching ${JENKINSFILE}"
  python3 - "${JENKINSFILE}" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = """            LOG=/tmp/sonar-scanner-$$.log
            npx --yes sonarqube-scanner@4.2.8 > "${LOG}" 2>&1
            RC=$?
            cat "${LOG}"
            if [ "${RC}" != "0" ] && grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' "${LOG}"; then
              echo "[sonar] scanner reported success despite exit ${RC} — treating as OK"
              RC=0
            fi
            if [ "${RC}" != "0" ]; then
              echo "[sonar] scanner tail:"
              tail -25 "${LOG}" 2>/dev/null || true
            fi
            rm -f "${LOG}" "${SP}"
            echo ${RC}
          ''', returnStdout: true).trim().tokenize('\\n').last()"""
new = """            if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
              export PATH="${JAVA_HOME}/bin:${PATH}"
            fi
            if ! command -v java >/dev/null 2>&1; then
              for _jb in /opt/java/openjdk/bin/java /usr/lib/jvm/java-17-openjdk-amd64/bin/java; do
                if [ -x "${_jb}" ]; then
                  export PATH="$(dirname "${_jb}"):${PATH}"
                  export JAVA_HOME="$(dirname "$(dirname "${_jb}")")"
                  break
                fi
              done
            fi
            if ! command -v java >/dev/null 2>&1; then
              echo "[sonar] ERROR: java not in PATH (sonarqube-scanner needs JRE). Use /opt/java/openjdk in Jenkins pod."
              exit 1
            fi
            echo "[sonar] java: $(java -version 2>&1 | head -1)"
            mkdir -p paas-artifacts
            LOG=paas-artifacts/sonar-scanner.log
            npx --yes sonarqube-scanner@4.2.8 > "${LOG}" 2>&1
            RC=$?
            cat "${LOG}"
            if [ "${RC}" != "0" ] && grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' "${LOG}"; then
              echo "[sonar] scanner reported success despite exit ${RC} — treating as OK"
              RC=0
            fi
            if [ "${RC}" != "0" ]; then
              echo "[sonar] scanner tail:"
              tail -40 "${LOG}" 2>/dev/null || true
            fi
            rm -f "${SP}"
            exit "${RC}"
          ''', returnStatus: true)"""
if old not in text:
    sys.stderr.write("ERROR: old Sonar block not found — git pull or copy Jenkinsfile from dev machine\\n")
    raise SystemExit(1)
text = text.replace(old, new, 1)
if "prependPath(\"/opt/java/openjdk/bin\")" not in text and "Docker CLI missing; using npm-based Sonar" in text:
    text = text.replace(
        'println "[sonar] Docker CLI missing; using npm-based Sonar scanner when configured."\n        ensureNodeTool()',
        'println "[sonar] Docker CLI missing; using npm-based Sonar scanner when configured."\n        ensureNodeTool()\n        prependPath("/opt/java/openjdk/bin")',
        1,
    )
path.write_text(text, encoding="utf-8")
print("patched OK")
PY
fi

echo "==> Push to Jenkins"
export JENKINSFILE="${JENKINSFILE}"
cd "${REPO_ROOT}"
set +u
# shellcheck disable=SC1090
source "${REPO_ROOT}/paas/frontend/docker-compose.env" 2>/dev/null || true
set -u
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force
echo "Done. Trigger build #316+ and grep console for: [sonar] java:  PAAS_STEP_OK step=5"
