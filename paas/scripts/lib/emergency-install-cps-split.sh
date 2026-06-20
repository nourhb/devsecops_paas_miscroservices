#!/usr/bin/env bash
# Self-contained fix for paas-deploy MethodTooLarge. No git pull required — only needs
# paas/jenkins/Jenkinsfile.paas-deploy on disk + kubectl + python3 on master.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
cd "${REPO_ROOT}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
PAAS_DIR="/var/jenkins_home/paas"
BUNDLE_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
MARKER="helm-portable-20260620-cps-split"
LOAD_MARKER="paas-deploy-stages-load-20260620-cps-split"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"

echo "=============================================="
echo " FIX paas-deploy MethodTooLarge (build #823+)"
echo " repo=${REPO_ROOT}"
echo "=============================================="

[[ -f "${JENKINSFILE}" ]] || { echo "ERROR: missing ${JENKINSFILE}" >&2; exit 1; }
command -v python3 >/dev/null || { echo "ERROR: python3 required on master" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "ERROR: kubectl required" >&2; exit 1; }

mkdir -p "${BUNDLE_DIR}"
export REPO_ROOT BUNDLE_DIR JENKINSFILE MARKER
python3 << 'PY'
import os, sys
from pathlib import Path

REPO_ROOT = Path(os.environ["REPO_ROOT"])
BUNDLE_DIR = Path(os.environ["BUNDLE_DIR"])
JENKINSFILE = Path(os.environ["JENKINSFILE"])
MARKER = os.environ["MARKER"]
LOAD_FILES = (
    "paas-deploy-load-h1.groovy",
    "paas-deploy-load-h2.groovy",
    "paas-deploy-load-h3.groovy",
    "paas-deploy-stages.groovy",
)
SPLIT_MARKER = "cps-split-dockerless-6abc-20260620"

def find_closure_end(lines, open_line):
    depth = started = 0
    for i in range(open_line, len(lines)):
        for ch in lines[i]:
            if ch == "{": depth += 1; started = True
            elif ch == "}": depth -= 1
        if started and depth == 0:
            return i
    raise ValueError(f"no matching brace at line {open_line + 1}")

def split_dockerless_push(text: str) -> str:
    if SPLIT_MARKER in text:
        return text
    start = text.index("def dockerlessImagePush(String craneBin, String imageRef, String dockerfilePath) {")
    s6a = text.index('  println "[image] Step 6a — npm deps', start)
    s6b = text.index('  println "[image] Step 6b — Next.js production build', start)
    verify = text.index("  verifyNextPublicEnvInBuild(appRoot)", start)
    s6c = text.index('  println "[image] Step 6c — layer tar + crane append', start)
    end_fn = text.index("\n}\n\ndef cosignSignImageShellSnippet", start)
    def wrap(name, params, body):
        return f"def {name}({params}) {{\n{body}\n}}\n\n"
    helpers = (
        f"// {SPLIT_MARKER}\n"
        + wrap("dockerlessImagePushCraneNode6a", "String appRoot", text[s6a:s6b].rstrip())
        + wrap("dockerlessImagePushCraneNode6b", "String appRoot, String imageStack", text[s6b:verify].rstrip())
        + wrap(
            "dockerlessImagePushCraneNode6c",
            "String craneBin, String imageRef, String artifactImageRef, String craneInsecure, String appRoot",
            text[s6c:end_fn].rstrip(),
        )
    )
    mid = (
        "  dockerlessImagePushCraneNode6a(appRoot)\n"
        "  dockerlessImagePushCraneNode6b(appRoot, imageStack)\n"
        "  verifyNextPublicEnvInBuild(appRoot)\n"
        "  dockerlessImagePushCraneNode6c(craneBin, imageRef, artifactImageRef, craneInsecure, appRoot)\n"
    )
    return text[:start] + helpers + text[start:s6a] + mid + text[end_fn:]

def find_stage_line_indices(body_lines):
    idx = [i for i, ln in enumerate(body_lines) if 'stage("Step ' in ln and "—" in ln]
    if len(idx) != 12:
        raise ValueError(f"expected 12 stages, found {len(idx)}")
    return idx

def split_helpers(lines, vars_start):
    helper_lines = lines[:vars_start]
    h1_end = next(i for i, ln in enumerate(helper_lines) if ln.startswith("def normalizeCosignPrivateKeyPem"))
    h2_end = next(i for i, ln in enumerate(helper_lines) if ln.startswith("def dockerlessImagePush("))
    return (
        "".join(helper_lines[:h1_end]),
        "".join(helper_lines[h1_end:h2_end]),
        "".join(helper_lines[h2_end:]),
    )

def split_stages_body(body_lines):
    stage_idx = find_stage_line_indices(body_lines)
    bounds = stage_idx + [len(body_lines)]
    groups = [
        ("runPaasDeploySteps1_2", 0, 2),
        ("runPaasDeployStep3", 2, 3),
        ("runPaasDeploySteps4_5", 3, 5),
        ("runPaasDeployStep6", 5, 6),
        ("runPaasDeploySteps7_8", 6, 8),
        ("runPaasDeploySteps9_12", 8, 12),
    ]
    out = []
    if stage_idx[0] > 0:
        init = "".join(body_lines[: stage_idx[0]]).rstrip() + "\n"
        out.append(f"def runPaasDeployEnvInit = {{\n{init}}}\n")
    for name, g0, g1 in groups:
        chunk = "".join(body_lines[bounds[g0] : bounds[g1]]).rstrip() + "\n"
        out.append(f"def {name} = {{\n{chunk}}}\n")
    out.append("def runPaasDeploy = {\n" + "\n".join([
        "  runPaasDeployEnvInit()",
        "  runPaasDeploySteps1_2()",
        "  runPaasDeployStep3()",
        "  runPaasDeploySteps4_5()",
        "  runPaasDeployStep6()",
        "  runPaasDeploySteps7_8()",
        "  runPaasDeploySteps9_12()",
    ]) + "\n}\n")
    return "".join(out)

def header(part):
    return (
        f"// generated inline ({part})\n"
        f"// dt-api-server-svc-20260617\n"
        f"// STAGES_BUNDLE_VERSION={MARKER}\n"
    )

text = JENKINSFILE.read_text(encoding="utf-8").replace("\r\n", "\n")
text = split_dockerless_push(text)
lines = text.splitlines(keepends=True)
vars_start = next(i for i, ln in enumerate(lines) if ln.startswith("def agentLabel = "))
body_start = next(i for i, ln in enumerate(lines) if ln.startswith("def runPaasDeploy = {"))
end = find_closure_end(lines, body_start)
h1, h2, h3 = split_helpers(lines, vars_start)
vars_block = "".join(lines[vars_start:body_start])
body_lines = lines[body_start + 1 : end]
stages_body = split_stages_body(body_lines)
bundle = {
    LOAD_FILES[0]: header("h1") + h1,
    LOAD_FILES[1]: header("h2") + h2,
    LOAD_FILES[2]: header("h3") + h3,
    LOAD_FILES[3]: header("stages") + vars_block + stages_body,
}
BUNDLE_DIR.mkdir(parents=True, exist_ok=True)
for name, content in bundle.items():
    p = BUNDLE_DIR / name
    p.write_text(content, encoding="utf-8")
    print(f"OK wrote {p} ({len(content)} bytes)", file=sys.stderr)
PY

echo "==> Install 4 files into Jenkins pod"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- mkdir -p "${PAAS_DIR}"
for f in paas-deploy-load-h1.groovy paas-deploy-load-h2.groovy paas-deploy-load-h3.groovy paas-deploy-stages.groovy; do
  echo "   ${f}"
  kubectl exec -i -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
    tee "${PAAS_DIR}/${f}" < "${BUNDLE_DIR}/${f}" >/dev/null
done

echo "==> Patch Jenkins job config (multi-load wrapper)"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  cat /var/jenkins_home/jobs/paas-deploy/config.xml > /tmp/paas-deploy-config.xml

python3 << PY
import re
from pathlib import Path
marker = "${LOAD_MARKER}"
bundle = "${MARKER}"
p = Path("/tmp/paas-deploy-config.xml")
t = p.read_text(encoding="utf-8")
new_script = f'''def paasLoadH1 = '/var/jenkins_home/paas/paas-deploy-load-h1.groovy'
def paasLoadH2 = '/var/jenkins_home/paas/paas-deploy-load-h2.groovy'
def paasLoadH3 = '/var/jenkins_home/paas/paas-deploy-load-h3.groovy'
def paasDeployStagesPath = '/var/jenkins_home/paas/paas-deploy-stages.groovy'
println '[paas-jenkinsfile] marker={marker} (Steps 1-12 via multi load — CPS split)'
def agentLabel = params.JENKINS_AGENT_LABEL?.trim() ?: ""
def paasRequireFreshStages = {{
  for (p in [paasLoadH1, paasLoadH2, paasLoadH3, paasDeployStagesPath]) {{
    if (!fileExists(p)) {{ error("Missing ${{p}}") }}
    if (!readFile(p).contains('{bundle}')) {{ error("Stale ${{p}} — re-run emergency-install-cps-split.sh") }}
  }}
  load paasLoadH1
  load paasLoadH2
  load paasLoadH3
  load paasDeployStagesPath
  runPaasDeploy()
}}
if (!agentLabel || agentLabel == 'built-in') {{
  println "[paas] node: default Built-In Node (agentLabel=\${{agentLabel ?: 'empty'}})"
  node {{ paasRequireFreshStages() }}
}} else {{
  println "[paas] node: agentLabel=\${{agentLabel}}"
  node(agentLabel) {{ paasRequireFreshStages() }}
}}
'''
m = re.search(
    r'(<definition\\b[^>]*class="org\\.jenkinsci\\.plugins\\.workflow\\.cps\\.CpsFlowDefinition"[^>]*>\\s*<script>\\s*<!\\[CDATA\\[)([\\s\\S]*?)(\\]\\]>\\s*</script>)',
    t, re.I)
if not m:
    raise SystemExit("ERROR: Pipeline CDATA not found in config.xml")
p.write_text(t[:m.start(2)] + new_script + t[m.end(2):], encoding="utf-8")
print("OK patched config.xml")
PY

kubectl exec -i -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  tee /var/jenkins_home/jobs/paas-deploy/config.xml < /tmp/paas-deploy-config.xml >/dev/null

echo ""
echo "==> Verification (must all print OK)"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- sh -c "
  grep -qF '${MARKER}' ${PAAS_DIR}/paas-deploy-load-h1.groovy && echo OK:h1
  grep -qF '${MARKER}' ${PAAS_DIR}/paas-deploy-stages.groovy && echo OK:stages
  grep -qF '${LOAD_MARKER}' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:job-marker
  grep -qF 'load paasLoadH1' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:multi-load
  grep -qF 'runPaasDeploy()' /var/jenkins_home/jobs/paas-deploy/config.xml && echo OK:run-call
  ls -la ${PAAS_DIR}/paas-deploy-*.groovy
"

echo ""
echo "=============================================="
echo " DONE. Start NEW build #824 (NOT Replay)."
echo " First lines MUST show:"
echo "   marker=${LOAD_MARKER}"
echo "   FOUR [Pipeline] load lines"
echo "   *** BEGIN : Check Parameters ***"
echo ""
echo " If marker still says 20260617, this script did not run or failed above."
echo "=============================================="
