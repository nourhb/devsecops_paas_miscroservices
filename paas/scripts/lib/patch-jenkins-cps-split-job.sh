#!/usr/bin/env bash
# Patch paas-deploy job config.xml to multi-load CPS wrapper (kubectl only — no Jenkins API).
set -euo pipefail
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
PAAS_DIR="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
MARKER="${DT_STAGES_MARKER:-helm-portable-20260620-cps-split}"
LOAD_MARKER="${PAAS_DEPLOY_STAGES_LOAD_MARKER:-paas-deploy-stages-load-20260620-cps-split}"
JOB_CFG="/var/jenkins_home/jobs/paas-deploy/config.xml"

echo "==> patch-jenkins-cps-split-job (ns=${JENKINS_NS}, marker=${LOAD_MARKER})"

kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- test -f "${JOB_CFG}"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  cat "${JOB_CFG}" > /tmp/paas-deploy-config.xml

export LOAD_MARKER MARKER PAAS_DIR
python3 << 'PY'
import os
import re
import sys
from pathlib import Path

marker = os.environ["LOAD_MARKER"]
bundle = os.environ["MARKER"]
paas_dir = os.environ["PAAS_DIR"]
p = Path("/tmp/paas-deploy-config.xml")
t = p.read_text(encoding="utf-8")
if marker in t and "load paasLoadH1" in t and "runPaasDeploy()" in t:
    print(f"OK: job config already has {marker} + multi-load + runPaasDeploy()")
    sys.exit(0)
new_script = f"""def paasLoadH1 = '{paas_dir}/paas-deploy-load-h1.groovy'
def paasLoadH2 = '{paas_dir}/paas-deploy-load-h2.groovy'
def paasLoadH3 = '{paas_dir}/paas-deploy-load-h3.groovy'
def paasDeployStagesPath = '{paas_dir}/paas-deploy-stages.groovy'
println '[paas-jenkinsfile] marker={marker} (Steps 1-12 via multi load — CPS split)'
def agentLabel = params.JENKINS_AGENT_LABEL?.trim() ?: ""
def paasRequireFreshStages = {{
  for (p in [paasLoadH1, paasLoadH2, paasLoadH3, paasDeployStagesPath]) {{
    if (!fileExists(p)) {{ error("Missing ${{p}}") }}
    if (!readFile(p).contains('{bundle}')) {{ error("Stale ${{p}} — re-run: bash paas/scripts/lab.sh fix-paas-deploy") }}
  }}
  load paasLoadH1
  load paasLoadH2
  load paasLoadH3
  load paasDeployStagesPath
  runPaasDeploy()
}}
if (!agentLabel || agentLabel == 'built-in') {{
  println "[paas] node: default Built-In Node (agentLabel=${{agentLabel ?: 'empty'}})"
  node {{ paasRequireFreshStages() }}
}} else {{
  println "[paas] node: agentLabel=${{agentLabel}}"
  node(agentLabel) {{ paasRequireFreshStages() }}
}}
"""
m = re.search(
    r'(<definition\b[^>]*class="org\.jenkinsci\.plugins\.workflow\.cps\.CpsFlowDefinition"[^>]*>\s*<script>\s*<!\[CDATA\[)([\s\S]*?)(\]\]>\s*</script>)',
    t,
    re.I,
)
if not m:
    print("ERROR: Pipeline CDATA not found in config.xml", file=sys.stderr)
    sys.exit(1)
p.write_text(t[: m.start(2)] + new_script + t[m.end(2) :], encoding="utf-8")
print("OK patched config.xml")
PY

kubectl exec -i -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  tee "${JOB_CFG}" < /tmp/paas-deploy-config.xml >/dev/null

kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- sh -c "
  grep -qF '${LOAD_MARKER}' ${JOB_CFG} && echo OK:job-marker
  grep -qF 'load paasLoadH1' ${JOB_CFG} && echo OK:multi-load
  grep -qF 'runPaasDeploy()' ${JOB_CFG} && echo OK:run-call
"
