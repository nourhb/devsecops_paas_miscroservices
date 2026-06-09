#!/usr/bin/env bash
# Fix SonarScanner CLI 6.x "Not authorized" when sonar.token is only in sonar-project.properties.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${JENKINSFILE:-${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy}"
MARKER="sonar-scanner-cli6-login-20260607"

[[ -f "${JENKINSFILE}" ]] || { echo "ERROR: missing ${JENKINSFILE}" >&2; exit 1; }

if grep -qF "printf 'sonar.login=%s" "${JENKINSFILE}" && grep -qF 'sonar-scanner-cli6-login-20260607' "${JENKINSFILE}"; then
  echo "OK: Jenkinsfile already has sonar.login + ${MARKER}"
else
  echo "==> Patching ${JENKINSFILE} for SonarScanner CLI 6 token auth"
  python3 - "${JENKINSFILE}" <<'PY'
import sys
from pathlib import Path
path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "printf 'sonar.login=%s" in text and "sonar-scanner-cli6-login-20260607" in text:
    print("already patched")
    raise SystemExit(0)
if "printf 'sonar.login=%s" not in text:
    old = """              printf 'sonar.token=%s\\n' \"${SONAR_TOKEN}\"
              printf 'sonar.projectKey=%s\\n' \"${SONAR_PROJECT_KEY}\""""
    new = """              printf 'sonar.token=%s\\n' \"${SONAR_TOKEN}\"
              printf 'sonar.login=%s\\n' \"${SONAR_TOKEN}\"
              printf 'sonar.projectKey=%s\\n' \"${SONAR_PROJECT_KEY}\""""
    if old not in text:
        raise SystemExit("ERROR: sonar.token block not found — git pull or scp Jenkinsfile from dev machine")
    text = text.replace(old, new, 1)
if '-Dsonar.login=' not in text:
    text = text.replace(
        '-Dsonar.token=\"${SONAR_TOKEN}\" \\\n                -Dsonar.ws.timeout=300',
        '-Dsonar.token=\"${SONAR_TOKEN}\" \\\n                -Dsonar.login=\"${SONAR_TOKEN}\" \\\n                -Dsonar.ws.timeout=300',
        1,
    )
marker_new = 'marker=sonar-scanner-cli6-login-20260607 (sonar.login+token; cluster URL; ws.timeout=300; retries)'
if marker_new not in text:
    for old_m in (
        'marker=sonar-ws-timeout-cluster-url-20260606',
        'marker=sonar-scanner-cli6-token-env-20260605',
        'marker=sonar-bash-rc-fix-20260603',
    ):
        if old_m in text:
            text = text.replace(
                f'println "[paas-jenkinsfile] {old_m}',
                f'println "[paas-jenkinsfile] {marker_new}',
                1,
            )
            break
    else:
        text = text.replace(
            'def sonarKey = dtProjectNameForUpload(projectId, imageName)',
            f'println "[paas-jenkinsfile] {marker_new}"\n      def sonarKey = dtProjectNameForUpload(projectId, imageName)',
            1,
        )
path.write_text(text, encoding="utf-8")
print("patched OK")
PY
fi

export JENKINSFILE="${JENKINSFILE}"
cd "${REPO_ROOT}"
set +u
# shellcheck disable=SC1090
source "${REPO_ROOT}/paas/frontend/docker-compose.env" 2>/dev/null || true
set -u
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true
echo "Done. Trigger NEW deploy; console must show marker ${MARKER} and PAAS_STEP_OK step=5"
