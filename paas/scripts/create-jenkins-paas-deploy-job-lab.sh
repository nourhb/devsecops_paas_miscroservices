#!/usr/bin/env bash
# Create Jenkins job paas-deploy from paas/jenkins/Jenkinsfile.paas-deploy (lab API).
# Run on k3s master when PaaS sync returns HTTP 500 or job is missing (404).
#
#   cd ~/devsecops_paas_miscroservices
#   JENKINS_API_TOKEN=xxx bash paas/scripts/create-jenkins-paas-deploy-job-lab.sh
#   # or reads JENKINS_* from paas/frontend/docker-compose.env
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
JOB_NAME="${JOB_NAME:-paas-deploy}"

if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
[[ -f "${ENV_FILE}" ]] && set -a && source "${ENV_FILE}" && set +a

BASE="${JENKINS_BASE_URL:-${JENKINS_URL:-http://127.0.0.1:30090}}"
BASE="${BASE%/}"
USER="${JENKINS_USERNAME:-${JENKINS_USER:-admin}}"
TOKEN="${JENKINS_API_TOKEN:-${JENKINS_TOKEN:-}}"

if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: set JENKINS_API_TOKEN (Jenkins → user → Configure → API Token)" >&2
  exit 1
fi

export BASE USER TOKEN JOB_NAME JENKINSFILE

python3 <<'PY'
import base64
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

base = os.environ["BASE"].rstrip("/")
user = os.environ["USER"]
token = os.environ["TOKEN"]
job = os.environ["JOB_NAME"]
groovy = Path(os.environ["JENKINSFILE"]).read_text(encoding="utf-8").replace("\r\n", "\n")
if not re.search(r"marker=steps-1-2-3", groovy):
    sys.exit("Jenkinsfile missing PaaS marker line — wrong file?")

auth = base64.b64encode(f"{user}:{token}".encode()).decode()
headers = {"Authorization": f"Basic {auth}"}

def req(url, method="GET", data=None, extra=None):
    h = dict(headers)
    if data is not None:
        h["Content-Type"] = "application/xml; charset=UTF-8"
    if extra:
        h.update(extra)
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=120) as resp:
            return resp.status, resp.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        return e.code, body

def escape_xml(t: str) -> str:
    return t.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

def escape_cdata(t: str) -> str:
    return t.replace("]]>", "]]]]><![CDATA[>")

PARAMS = [
    ("JENKINS_AGENT_LABEL", "built-in", "Agent label"),
    ("GIT_URL", "", "Repository URL"),
    ("BRANCH", "main", "Branch"),
    ("IMAGE_NAME", "", "Image without tag"),
    ("PROJECT_ID", "", "PaaS project UUID"),
    ("GIT_CREDENTIALS_ID", "", "Jenkins credentialsId for Git"),
    ("HARBOR_REGISTRY", "", "Harbor host"),
    ("HARBOR_USERNAME", "", "Harbor user"),
    ("HARBOR_PASSWORD", "", "Harbor password"),
    ("JENKINS_PAAS_FAST_PIPELINE", "false", "Fast pipeline flag"),
]

def param_xml():
    lines = []
    for name, default, desc in PARAMS:
        lines.append(
            f'      <hudson.model.StringParameterDefinition>\n'
            f'        <name>{escape_xml(name)}</name>\n'
            f'        <description>{escape_xml(desc)}</description>\n'
            f'        <defaultValue>{escape_xml(default)}</defaultValue>\n'
            f'        <trim>true</trim>\n'
            f'      </hudson.model.StringParameterDefinition>'
        )
    return "\n".join(lines)

inner = escape_cdata(groovy)
xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<flow-definition plugin="workflow-job">
  <description>paas-deploy (created by create-jenkins-paas-deploy-job-lab.sh)</description>
  <keepDependencies>false</keepDependencies>
  <properties>
    <hudson.model.ParametersDefinitionProperty>
      <parameterDefinitions>
{param_xml()}
      </parameterDefinitions>
    </hudson.model.ParametersDefinitionProperty>
  </properties>
  <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps">
    <script><![CDATA[{inner}]]></script>
    <sandbox>true</sandbox>
  </definition>
  <triggers/>
  <disabled>false</disabled>
</flow-definition>
"""

code, body = req(f"{base}/api/json")
print(f"GET /api/json → HTTP {code}")
if code != 200:
    print(body[:800])
    sys.exit(1)

crumb_h, crumb_v = None, None
c_code, c_body = req(f"{base}/crumbIssuer/api/json")
if c_code == 200:
    j = json.loads(c_body)
    crumb_h, crumb_v = j.get("crumbRequestField"), j.get("crumb")
    print(f"Crumb: {crumb_h}")

job_url = f"{base}/job/{urllib.parse.quote(job)}/api/json"
code, _ = req(job_url)
if code == 200:
    print(f"Job '{job}' already exists at {base}/job/{job}/")
    sys.exit(0)

extra = {}
if crumb_h and crumb_v:
    extra[crumb_h] = crumb_v

create_url = f"{base}/createItem?name={urllib.parse.quote(job)}"
code, body = req(create_url, method="POST", data=xml.encode("utf-8"), extra=extra)
print(f"POST /createItem → HTTP {code}")
if code not in (200, 201, 302):
    print(body[:4000])
    sys.exit(1)

code, _ = req(job_url)
print(f"Verify job → HTTP {code}")
print(f"OK: {base}/job/{job}/")
PY

echo ""
echo "Set JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false in docker-compose.env if you only want triggers."
echo "PaaS Deploy: http://192.168.56.129:30100"
