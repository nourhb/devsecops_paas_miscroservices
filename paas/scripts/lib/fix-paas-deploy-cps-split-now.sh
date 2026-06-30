#!/usr/bin/env bash
# Standalone fix: 7-file CPS split on jenkins-0 + POST wrapper (fixes MethodTooLarge).
# Works on lab StatefulSet jenkins-0 — does NOT use deploy/jenkins or monolith load.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"
REMOTE="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
RENDER="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
BUNDLE="helm-portable-20260620-cps-split"
CPS_MARKER="paas-deploy-stages-load-20260620-cps-split"

cd "${REPO_ROOT}"

echo "=============================================="
echo " FIX paas-deploy: 7-file CPS split (jenkins-0)"
echo "=============================================="

kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null 2>&1 || {
  echo "FAIL: pod ${JENKINS_NS}/${JPOD} not found (lab uses StatefulSet jenkins-0, not deploy/jenkins)" >&2
  exit 1
}

echo "==> 1/5 Render 7-file CPS bundle from paas/jenkins/Jenkinsfile.paas-deploy"
rm -rf "${RENDER}"
mkdir -p "${RENDER}"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
RENDER_PY="${REPO_ROOT}/paas/jenkins/render-loadable-stages.py"
render_ok=0
if [[ -f "${RENDER_PY}" ]] && [[ -f "${JENKINSFILE}" ]]; then
  python3 "${REPO_ROOT}/paas/jenkins/split-cps-hotspots.py" 2>/dev/null || true
  if python3 "${RENDER_PY}" --out-dir "${RENDER}"; then
    render_ok=1
  fi
fi
if [[ "${render_ok}" != "1" ]] \
  && [[ -f "${SCRIPT_DIR}/install-jenkins-stages-file.sh" ]] \
  && grep -qF 'paas-deploy-stages-p1.groovy' "${SCRIPT_DIR}/install-jenkins-stages-file.sh"; then
  echo "WARN: render-loadable-stages.py failed — trying install-jenkins-stages-file.sh"
  PAAS_RENDER_DIR="${RENDER}" RENDER_ONLY=1 SKIP_JOB_PATCH=1 bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh" 2>&1 | grep -E '^OK|^==>|^FAIL|ERROR' || true
  [[ -f "${RENDER}/paas-deploy-stages-p3.groovy" ]] && render_ok=1
fi
if [[ "${render_ok}" != "1" ]] && [[ -d "${REPO_ROOT}/paas/jenkins/.render-test" ]]; then
  echo "WARN: fresh render failed — using paas/jenkins/.render-test/ (may lack latest Jenkinsfile fixes; rm -rf it after git pull)"
  cp "${REPO_ROOT}/paas/jenkins/.render-test"/paas-deploy-*.groovy "${RENDER}/"
fi

if [[ ! -f "${RENDER}/paas-deploy-stages-p3.groovy" ]]; then
  echo "FAIL: no split bundle — copy fix-paas-deploy-cps-split-now.sh + jenkins_merge_cps_wrapper.py from dev machine" >&2
  echo "  Or: git pull && bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh" >&2
  exit 1
fi

# Sanitize + dedupe p3 (VM stale render often has 2x def runPaasDeploy())
p3="${RENDER}/paas-deploy-stages-p3.groovy"
if [[ -f "${p3}" ]]; then
  if [[ -x "${SCRIPT_DIR}/fix-p3-no-self-invoke.sh" ]]; then
    PAAS_RENDER_DIR="${RENDER}" bash "${SCRIPT_DIR}/fix-p3-no-self-invoke.sh" 2>/dev/null || true
  fi
  python3 - "${p3}" <<'PY'
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")

# Stale render-loadable-stages.py used closure syntax; monolith assembler expects methods.
t = t.replace("def runPaasDeploy = {", "def runPaasDeploy() {")

def end_of_block(s: str, start: int) -> int:
    depth = 0
    for i in range(start, len(s)):
        if s[i] == "{":
            depth += 1
        elif s[i] == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("unbalanced braces")

m = "def runPaasDeploy() {"
while t.count(m) > 1:
    first = t.find(m)
    fe = end_of_block(t, first + len(m) - 1)
    second = t.find(m, fe)
    if second < 0:
        break
    se = end_of_block(t, second + len(m) - 1)
    t = t[:second] + t[se:]
lines = t.splitlines()
while lines and lines[-1].strip() in ("", "runPaasDeploy()"):
    lines.pop()
out = "\n".join(lines) + "\n"
p.write_text(out, encoding="utf-8")
if out.count(m) != 1:
    if out.count("def runPaasDeploy = {") == 1:
        out = out.replace("def runPaasDeploy = {", m)
        p.write_text(out, encoding="utf-8")
        print(f"OK: p3 normalized runPaasDeploy closure -> method ({len(out)} bytes)")
        sys.exit(0)
    sys.exit(f"ERROR: p3 has {out.count(m)} def runPaasDeploy() after dedupe")
print(f"OK: p3 deduped to 1 def runPaasDeploy() ({len(out)} bytes)")
PY
fi

# Ensure bundle marker on every split file (VM rollback may render dt-api-server-svc-20260617)
for f in paas-deploy-load-h1.groovy paas-deploy-load-h2.groovy paas-deploy-load-h3.groovy \
         paas-deploy-stages-vars.groovy paas-deploy-stages-p1.groovy paas-deploy-stages-p2.groovy \
         paas-deploy-stages-p3.groovy; do
  fp="${RENDER}/${f}"
  [[ -f "${fp}" ]] || { echo "FAIL: missing ${fp}" >&2; exit 1; }
  if ! grep -qF "${BUNDLE}" "${fp}"; then
    sed -i "1i// STAGES_BUNDLE_VERSION=${BUNDLE}" "${fp}"
  fi
done

grep -qF 'def runPaasDeploy()' "${p3}" || { echo "FAIL: p3 missing def runPaasDeploy()" >&2; exit 1; }
p3_count="$(grep -c 'def runPaasDeploy()' "${p3}" || true)"
[[ "${p3_count}" == "1" ]] || { echo "FAIL: p3 has ${p3_count} def runPaasDeploy() — dedupe failed" >&2; exit 1; }
grep -qF 'def coerceHarborHostForCosign' "${RENDER}/paas-deploy-load-h3.groovy" \
  || grep -qF 'def coerceHarborHostForCosign' "${RENDER}/paas-deploy-load-h2.groovy" \
  || { echo "FAIL: helpers missing in h2/h3" >&2; exit 1; }

if grep -qF 'sonar-checkpoint-poll-20260630' "${JENKINSFILE}" 2>/dev/null; then
  poll_render="$(grep -c 'sonar-checkpoint-poll-20260630' "${RENDER}/paas-deploy-stages-p2.groovy" 2>/dev/null || echo 0)"
  if [[ "${poll_render}" != "1" ]]; then
    echo "FAIL: Jenkinsfile has sonar-checkpoint-poll but render p2 does not (stale render-loadable-stages.py on VM?)" >&2
    echo "  git pull && rm -rf paas/jenkins/.render-test /var/tmp/paas-deploy-bundle && re-run" >&2
    exit 1
  fi
  echo "OK: Sonar checkpoint-poll marker present in rendered p2 (Step 5)"
fi

echo "==> 2/5 Push 7 split files to ${JENKINS_NS}/${JPOD}:${REMOTE}"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- mkdir -p "${REMOTE}"
for f in paas-deploy-load-h1.groovy paas-deploy-load-h2.groovy paas-deploy-load-h3.groovy \
         paas-deploy-stages-vars.groovy paas-deploy-stages-p1.groovy paas-deploy-stages-p2.groovy \
         paas-deploy-stages-p3.groovy; do
  bytes="$(wc -c < "${RENDER}/${f}" | tr -d ' ')"
  echo "   ${f} (${bytes} bytes)"
  kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s \
    -- tee "${REMOTE}/${f}" < "${RENDER}/${f}" >/dev/null
done

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- grep -qF "${BUNDLE}" "${REMOTE}/paas-deploy-stages-p3.groovy"
p3_on_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- grep -c 'def runPaasDeploy()' "${REMOTE}/paas-deploy-stages-p3.groovy" | tr -d '\r\n')"
[[ "${p3_on_pod}" == "1" ]] || {
  echo "FAIL: pod p3 has ${p3_on_pod} def runPaasDeploy() after push — dedupe failed" >&2
  exit 1
}
echo "OK: 7 split files on pod (p3 runPaasDeploy count=1)"

echo "==> 2b/5 Assemble monolith paas-deploy-stages.groovy on pod"
ASSEMBLE="${SCRIPT_DIR}/assemble-paas-deploy-monolith.sh"
if [[ ! -f "${ASSEMBLE}" ]]; then
  echo "FAIL: ${ASSEMBLE} missing — git pull origin/main" >&2
  exit 1
fi
chmod +x "${ASSEMBLE}" 2>/dev/null || true
bash "${ASSEMBLE}"

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- grep -qF 'return this' "${REMOTE}/paas-deploy-stages.groovy"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- sh -c "grep -c 'def runPaasDeploy()' '${REMOTE}/paas-deploy-stages.groovy' | grep -qx 1"
_def_pid="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- sh -c "grep -c '^def projectId' '${REMOTE}/paas-deploy-stages.groovy' 2>/dev/null || echo 0" | tr -d '\r\n')"
[[ "${_def_pid}" == "0" ]] || { echo "FAIL: monolith has def projectId (broken CPS binding) — re-run assemble" >&2; exit 1; }
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- grep -qE '^projectId\s*=' "${REMOTE}/paas-deploy-stages.groovy" \
  || { echo "FAIL: monolith missing binding var projectId=" >&2; exit 1; }
echo "OK: monolith on pod (1 runPaasDeploy + return this + projectId binding)"

echo "==> 3/5 Disable PaaS UI job revert"
for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
  [[ -f "${f}" ]] || continue
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${f}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${f}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${f}"
  fi
done

echo "==> 4/5 POST monolith CPS wrapper to Jenkins LIVE"
set -a
# shellcheck disable=SC1091
source "${ENV_FILE}" 2>/dev/null || true
set +a

if [[ -f "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py" ]] \
  && [[ -f "${SCRIPT_DIR}/jenkins_merge_cps_wrapper.py" ]]; then
  python3 "${SCRIPT_DIR}/post-paas-deploy-wrapper-live.py"
else
  python3 <<'PY'
import base64, json, os, re, sys, urllib.error, urllib.request, http.cookiejar
from pathlib import Path
from xml.sax.saxutils import escape

PAAS_DIR = "/var/jenkins_home/paas"
MARKER = "paas-deploy-stages-load-20260620-cps-split"
BUNDLE = "helm-portable-20260620-cps-split"
SPLIT = (
    ("paasLoadH1", "paas-deploy-load-h1.groovy"),
    ("paasLoadH2", "paas-deploy-load-h2.groovy"),
    ("paasLoadH3", "paas-deploy-load-h3.groovy"),
    ("paasStagesVars", "paas-deploy-stages-vars.groovy"),
    ("paasStagesP1", "paas-deploy-stages-p1.groovy"),
    ("paasStagesP2", "paas-deploy-stages-p2.groovy"),
    ("paasStagesP3", "paas-deploy-stages-p3.groovy"),
)
path_defs = "\n".join(f"def {v} = '{PAAS_DIR}/{f}'" for v, f in SPLIT)
load_lines = "\n".join(f"  load {v}" for v, _ in SPLIT)
stale = "\n".join(
    f"""  if (!fileExists({v})) {{ error("Missing ${{{v}}} — re-run fix-paas-deploy-cps-split-now.sh") }}
  if (!readFile({v}).contains('{BUNDLE}')) {{ error("Stale ${{{v}.tokenize('/')[-1]}}") }}"""
    for v, _ in SPLIT
)
wrapper = f"""def paasDir = '{PAAS_DIR}'
def paasDeployStages = '{PAAS_DIR}/paas-deploy-stages.groovy'
println '[paas-jenkinsfile] marker={MARKER} (assembled monolith load + paas.runPaasDeploy)'
def agentLabel = params.JENKINS_AGENT_LABEL?.trim() ?: ""
def paasRequireFreshStages = {{
  if (!fileExists(paasDeployStages)) {{ error("Missing monolith — run assemble-paas-deploy-monolith.sh") }}
  def stagesText = readFile(paasDeployStages)
  if (!stagesText.contains('{BUNDLE}')) {{ error("Stale monolith") }}
  if (!stagesText.contains('def runPaasDeploy()')) {{ error("Stale monolith (no runPaasDeploy)") }}
  if (!stagesText.contains('return this')) {{ error("Stale monolith (no return this)") }}
  def paas = load paasDeployStages
  paas.runPaasDeploy()
}}
if (!agentLabel || agentLabel == 'built-in') {{
  node {{ paasRequireFreshStages() }}
}} else {{
  node(agentLabel) {{ paasRequireFreshStages() }}
}}
"""
CPS_FLOW = "org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition"
CDATA = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(CPS_FLOW)}"[^>]*>\s*<script>\s*<!\[CDATA\[)([\s\S]*?)(\]\]>\s*</script>)',
    re.I,
)
PLAIN = re.compile(
    rf'(<definition\b[^>]*class="{re.escape(CPS_FLOW)}"[^>]*>\s*<script>)([\s\S]*?)(</script>)',
    re.I,
)

def merge(xml, groovy):
    m = CDATA.search(xml)
    if m:
        inner = groovy.replace("]]>", "]]]]><![CDATA[>")
        return xml[: m.start(2)] + inner + xml[m.end(2) :]
    m = PLAIN.search(xml)
    if not m:
        raise SystemExit("FAIL: no pipeline script in config.xml")
    return xml[: m.start(2)] + escape(groovy) + xml[m.end(2) :]

vals = {}
for line in Path("paas/frontend/docker-compose.env").read_text(encoding="utf-8", errors="replace").splitlines():
    line = line.strip()
    if line and not line.startswith("#") and "=" in line:
        k, _, v = line.partition("=")
        vals[k.strip()] = v.strip().strip('"')
base = (os.environ.get("JENKINS_PROBE_URL") or vals.get("JENKINS_PROBE_URL") or "http://192.168.56.129:30090").rstrip("/")
user = os.environ.get("JENKINS_USERNAME") or vals.get("JENKINS_USERNAME") or ""
token = os.environ.get("JENKINS_API_TOKEN") or vals.get("JENKINS_API_TOKEN") or ""
job = os.environ.get("JENKINS_JOB_NAME") or "paas-deploy"
if not user or not token:
    sys.exit("FAIL: set JENKINS_USERNAME + JENKINS_API_TOKEN in docker-compose.env")
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

def call(path, method="GET", data=None, extra=None):
    h = {"Authorization": f"Basic {auth}"}
    if data is not None:
        h["Content-Type"] = "application/xml; charset=UTF-8"
    if extra:
        h.update(extra)
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=h)
    try:
        with opener.open(req, timeout=120) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

code, body = call(f"/job/{job}/config.xml")
if code != 200:
    sys.exit(f"FAIL: GET config.xml HTTP {code}")
merged = merge(body, wrapper)
extra = {}
ccode, cbody = call("/crumbIssuer/api/json")
if ccode == 200:
    c = json.loads(cbody)
    extra = {c["crumbRequestField"]: c["crumb"]}
pcode, _ = call(f"/job/{job}/config.xml", "POST", merged.encode("utf-8"), extra)
print(f"POST config.xml -> {pcode}")
if pcode not in (200, 201):
    sys.exit(1)
_, live = call(f"/job/{job}/config.xml")
checks = ("load paasDeployStages", "paas.runPaasDeploy()", MARKER)
for need in checks:
    if need not in live and need.replace("(", "&#40;").replace(")", "&#41;") not in live:
        sys.exit(f"FAIL: LIVE missing {need!r}")
print("OK: Jenkins LIVE uses assembled monolith load + paas.runPaasDeploy()")
PY
fi

echo "==> 5/5 Verify pod monolith + LIVE job"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  sh -c "grep -qF 'return this' '${REMOTE}/paas-deploy-stages.groovy'"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  sh -c "test \"\$(grep -c 'def runPaasDeploy()' '${REMOTE}/paas-deploy-stages.groovy' | tr -d '\\r')\" = 1"
echo "OK: pod monolith verified (return this + 1× runPaasDeploy)"
if grep -qF 'sonar-checkpoint-poll-20260630' "${JENKINSFILE}" 2>/dev/null; then
  poll_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
    grep -c 'sonar-checkpoint-poll-20260630' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${poll_pod}" == "1" ]]; then
    echo "OK: Sonar checkpoint-poll marker on pod monolith"
  else
    echo "FAIL: pod monolith missing sonar-checkpoint-poll (got ${poll_pod}) — abort before deploy" >&2
    exit 1
  fi
fi

echo ""
echo "=============================================="
echo " DONE — trigger NEW paas-deploy (NOT Replay)"
echo ""
echo " Console MUST show:"
 echo "   marker=${CPS_MARKER}"
 echo "   load paas-deploy-stages.groovy + paas.runPaasDeploy()"
 echo "   *** BEGIN : Check Parameters ***"
echo "=============================================="
