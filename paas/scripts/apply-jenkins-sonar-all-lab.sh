#!/usr/bin/env bash
# Apply all Sonar Step 5 fixes on lab VM (no git pull required). Idempotent.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${JENKINSFILE:-${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy}"

[[ -f "${JENKINSFILE}" ]] || { echo "ERROR: missing ${JENKINSFILE}" >&2; exit 1; }

python3 - "${JENKINSFILE}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
t = path.read_text(encoding="utf-8")
changed = []

def need(marker: str) -> bool:
    return marker not in t

# 1) Token env + npx -D (Scanner CLI 6 auth)
if need("sonar-scanner-cli6-token-env-20260605") and "paas-artifacts/sonar-scanner.log" in t:
    old = """              printf 'sonar.token=%s\\n' \"${SONAR_TOKEN}\"
              printf 'sonar.projectKey=%s\\n' \"${SONAR_PROJECT_KEY}\""""
    new = """              printf 'sonar.token=%s\\n' \"${SONAR_TOKEN}\"
              printf 'sonar.projectKey=%s\\n' \"${SONAR_PROJECT_KEY}\""""
    if "printf 'sonar.login=%s\\n'" not in t and old in t:
        new = """              printf 'sonar.token=%s\\n' \"${SONAR_TOKEN}\"
              printf 'sonar.projectKey=%s\\n' \"${SONAR_PROJECT_KEY}\""""
    old_npx = """            LOG=paas-artifacts/sonar-scanner.log
            npx --yes sonarqube-scanner@4.2.8 > \"${LOG}\" 2>&1"""
    new_npx = """            LOG=paas-artifacts/sonar-scanner.log
            export SONAR_TOKEN=\"${SONAR_TOKEN}\"
            export SONAR_HOST_URL=\"${SONAR_HOST_URL}\"
            npx --yes sonarqube-scanner@4.2.8 \\
              -Dsonar.host.url=\"${SONAR_HOST_URL}\" \\
              -Dsonar.token=\"${SONAR_TOKEN}\" \\
              -Dsonar.ws.timeout=300 \\
              > \"${LOG}\" 2>&1"""
    if old_npx in t and "export SONAR_TOKEN" not in t:
        t = t.replace(old_npx, new_npx, 1)
        changed.append("token-env-npx")
    if "sonar-scanner-cli6-token-env-20260605" not in t:
        t = t.replace(
            "marker=sonar-bash-rc-fix-20260603",
            "marker=sonar-scanner-cli6-token-env-20260605",
            1,
        )

# 2) Cluster URL first + retries + sonar.ws.timeout in properties
if need("sonar-ws-timeout-cluster-url-20260606"):
    t = t.replace(
        """            pick_sonar_url() {
              for u in \\
                \"${SONAR_HOST_URL_PARAM}\" \\
                \"http://sonarqube-service.sonarqube.svc.cluster.local:9000\" \\
                \"http://sonarqube.sonarqube.svc.cluster.local:9000\"""",
        """            pick_sonar_url() {
              for u in \\
                \"http://sonarqube-service.sonarqube.svc.cluster.local:9000\" \\
                \"http://sonarqube.sonarqube.svc.cluster.local:9000\" \\
                \"${SONAR_HOST_URL_PARAM}\"""",
        1,
    )
    t = t.replace(
        'curl -fsS -m 8 -u "${SONAR_TOKEN}:"',
        'curl -fsS -m 15 -u "${SONAR_TOKEN}:"',
        1,
    )
    if "printf 'sonar.ws.timeout=%s\\n' '300'" not in t:
        t = t.replace(
            "printf 'sonar.scanner.analysisCacheEnabled=%s\\n' 'false'",
            "printf 'sonar.scanner.analysisCacheEnabled=%s\\n' 'false'\n"
            "              printf 'sonar.ws.timeout=%s\\n' '300'",
            1,
        )
    old_loop = """            npx --yes sonarqube-scanner@4.2.8 \\
              -Dsonar.host.url=\"${SONAR_HOST_URL}\" \\
              -Dsonar.token=\"${SONAR_TOKEN}\" \\
              -Dsonar.ws.timeout=300 \\
              > \"${LOG}\" 2>&1
            RC=$?"""
    new_loop = """            RC=1
            for _sonar_try in 1 2 3; do
              echo \"[sonar] scanner attempt ${_sonar_try}/3\"
              npx --yes sonarqube-scanner@4.2.8 \\
                -Dsonar.host.url=\"${SONAR_HOST_URL}\" \\
                -Dsonar.token=\"${SONAR_TOKEN}\" \\
                -Dsonar.ws.timeout=300 \\
                > \"${LOG}\" 2>&1
              RC=$?
              if [ \"${RC}\" = \"0\" ]; then break; fi
              if grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' \"${LOG}\"; then RC=0; break; fi
              if grep -qE 'SocketTimeoutException|Read timed out|values\\\\.protobuf' \"${LOG}\" && [ \"${_sonar_try}\" -lt 3 ]; then
                echo \"[sonar] WARN: Sonar API timeout — retry in 30s\"
                sleep 30
                continue
              fi
              break
            done"""
    if old_loop in t and "scanner attempt" not in t:
        t = t.replace(old_loop, new_loop, 1)
        changed.append("ws-timeout-retry")
    t = t.replace(
        "marker=sonar-scanner-cli6-token-env-20260605",
        "marker=sonar-ws-timeout-cluster-url-20260606",
        1,
    )
    if "marker=sonar-ws-timeout-cluster-url-20260606" not in t:
        t = t.replace(
            'def sonarKey = dtProjectNameForUpload(projectId, imageName)',
            'println "[paas-jenkinsfile] marker=sonar-ws-timeout-cluster-url-20260606"\n      def sonarKey = dtProjectNameForUpload(projectId, imageName)',
            1,
        )

# 3) Groovy: PAAS_STEP_OK when log has EXECUTION SUCCESS
if need("sonarLog.contains"):
    old_groovy = """          if (sonarRc != 0) {
            paasStepWarn(5, 'sonar', \"scanner exit ${sonarRc} — see scanner tail above; bash paas/scripts/diagnose-sonar-jenkins-lab.sh\")
          } else {
            paasStepOk(5, 'sonar', \"analysis submitted for projectKey=${sonarKey}\")
          }"""
    new_groovy = """          def sonarLog = fileExists('paas-artifacts/sonar-scanner.log') ? readFile('paas-artifacts/sonar-scanner.log') : ''
          def sonarPassed = (sonarRc as Integer) == 0 \\
            || sonarLog.contains('EXECUTION SUCCESS') \\
            || sonarLog.contains('ANALYSIS SUCCESSFUL')
          if (sonarPassed) {
            paasStepOk(5, 'sonar', \"analysis submitted for projectKey=${sonarKey}\")
          } else {
            paasStepWarn(5, 'sonar', \"scanner exit ${sonarRc} — see paas-artifacts/sonar-scanner.log\")
          }"""
    if old_groovy in t:
        t = t.replace(old_groovy, new_groovy, 1)
        changed.append("sonarLog-groovy")

path.write_text(t, encoding="utf-8")
print("patched:", ", ".join(changed) if changed else "already up to date")
PY

grep -nE 'sonar-ws-timeout|sonarLog.contains|paas-artifacts/sonar-scanner' "${JENKINSFILE}" | head -5

export JENKINSFILE
cd "${REPO_ROOT}"
set +u
# shellcheck disable=SC1090
source "${REPO_ROOT}/paas/frontend/docker-compose.env" 2>/dev/null || true
set -u
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" 2>/dev/null || true
echo "Done. Trigger NEW deploy; expect PAAS_STEP_OK step=5 when Sonar succeeds."
