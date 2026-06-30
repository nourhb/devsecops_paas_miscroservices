#!/usr/bin/env bash
# Assemble paas-deploy-stages.groovy monolith from the 7 split files ALREADY on jenkins-0,
# guaranteeing: helm marker, def runPaasDeploy() orchestrator, and trailing `return this`.
# Independent of render-loadable-stages.py (VM copy may be stale). Pushes result to jenkins-0.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
REMOTE_DIR="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
BUNDLE="${DT_STAGES_MARKER:-helm-portable-20260620-cps-split}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/paas-mono.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

SPLIT_FILES=(
  paas-deploy-load-h1.groovy
  paas-deploy-load-h2.groovy
  paas-deploy-load-h3.groovy
  paas-deploy-stages-vars.groovy
  paas-deploy-stages-p1.groovy
  paas-deploy-stages-p2.groovy
  paas-deploy-stages-p3.groovy
)

kexec() { kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=120s -- "$@"; }
kexec_i() { kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JENKINS_CONTAINER}" --request-timeout=120s -- "$@"; }

echo "==> Pull 7 split files from ${JENKINS_NS}/${JPOD}:${REMOTE_DIR}"
for f in "${SPLIT_FILES[@]}"; do
  kexec cat "${REMOTE_DIR}/${f}" > "${WORK}/${f}"
  bytes="$(wc -c < "${WORK}/${f}" | tr -d ' ')"
  [[ "${bytes}" -gt 0 ]] || { echo "FAIL: ${f} empty on pod" >&2; exit 1; }
  grep -qF "${BUNDLE}" "${WORK}/${f}" || { echo "FAIL: ${f} missing ${BUNDLE}" >&2; exit 1; }
  echo "   ${f} (${bytes} bytes)"
done

echo "==> Assemble monolith with orchestrator + return this"
python3 - "${WORK}" <<'PY'
import re
import sys
from pathlib import Path

work = Path(sys.argv[1])
order = [
    "paas-deploy-load-h1.groovy",
    "paas-deploy-load-h2.groovy",
    "paas-deploy-load-h3.groovy",
    "paas-deploy-stages-vars.groovy",
    "paas-deploy-stages-p1.groovy",
    "paas-deploy-stages-p2.groovy",
    "paas-deploy-stages-p3.groovy",
]
def transform(text, deep):
    # Top-level closures -> methods (survive `load file; obj.method()`):
    #   `def NAME = { args -> `  -> `def NAME(args) {`
    #   `def NAME = {`           -> `def NAME() {`
    # Column-0 scalar state -> binding var (shared param vars across split methods).
    # In step files (deep=True) also 2-space-indent scalars -> binding: these were
    # closure-locals in the original single runPaasDeploy closure (e.g. paasFastPipeline,
    # cranePushTimeoutMin) and are read across split functions. Helper files keep their
    # internal locals (deep=False) to avoid cross-call clobbering.
    out = []
    for ln in text.split("\n"):
        m = re.match(r'^def (\w+)\s*=\s*\{\s*(.*?)\s*->\s*$', ln)
        if m:
            out.append(f"def {m.group(1)}({m.group(2)}) {{")
            continue
        m = re.match(r'^def (\w+)\s*=\s*\{\s*$', ln)
        if m:
            out.append(f"def {m.group(1)}() {{")
            continue
        m = re.match(r'^def (\w+)(\s*=\s*)(?!\{)(.*)$', ln)
        if m:
            out.append(f"{m.group(1)}{m.group(2)}{m.group(3)}")
            continue
        if deep:
            m = re.match(r'^  def (\w+)(\s*=\s*)(?!\{)(.*)$', ln)
            if m:
                out.append(f"  {m.group(1)}{m.group(2)}{m.group(3)}")
                continue
        out.append(ln)
    return "\n".join(out)


HELPER_FILES = {"paas-deploy-load-h1.groovy", "paas-deploy-load-h2.groovy", "paas-deploy-load-h3.groovy"}
parts = []
for name in order:
    text = (work / name).read_text(encoding="utf-8").replace("\r\n", "\n")
    deep = name not in HELPER_FILES
    parts.append(transform(text, deep).rstrip("\n") + "\n")
body = "\n".join(parts)

# Drop any stray top-level `return this` from split files (only the monolith ends with one).
lines = [ln for ln in body.split("\n")]
lines = [ln for ln in lines if ln.strip() != "return this"]
body = "\n".join(lines).rstrip("\n") + "\n"

# Keep exactly one orchestrator (duplicate breaks CPS load with "duplicates another method").
def dedupe_run_paas_deploy(text: str) -> str:
    pat = re.compile(r"def runPaasDeploy\(\) \{\n.*?\n\}\n", re.DOTALL)
    matches = list(pat.finditer(text))
    if len(matches) <= 1:
        return text
    out = text
    for m in reversed(matches[1:]):
        out = out[: m.start()] + out[m.end() :]
    return out


body = dedupe_run_paas_deploy(body)

step_fns = [
    "runPaasDeployEnvInit",
    "runPaasDeploySteps1_2",
    "runPaasDeployStep3",
    "runPaasDeploySteps4_5",
    "runPaasDeployStep6",
    "runPaasDeploySteps7_8",
    "runPaasDeploySteps9_12",
]
present = [f"{fn}()" for fn in step_fns if f"def {fn}(" in body]
missing = [fn for fn in step_fns if f"def {fn}(" not in body]
if missing:
    sys.exit(f"FAIL: split files missing step functions: {missing}")

if "def runPaasDeploy()" not in body:
    orchestrator = "def runPaasDeploy() {\n" + "\n".join(f"  {c}" for c in present) + "\n}\n"
    body = body + orchestrator

body = dedupe_run_paas_deploy(body)
if body.count("def runPaasDeploy()") != 1:
    sys.exit(f"FAIL: expected 1 def runPaasDeploy(), found {body.count('def runPaasDeploy()')}")

body = body.rstrip("\n") + "\nreturn this\n"

out = work / "paas-deploy-stages.groovy"
out.write_text(body, encoding="utf-8")

# Self-check (same assertions the job wrapper makes)
checks = {
    "helm marker": body.count("helm-portable-20260620-cps-split") >= 1,
    "def runPaasDeploy()": "def runPaasDeploy()" in body,
    "return this (trailing)": body.rstrip().endswith("return this"),
    "coerceHarborHostForCosign": "def coerceHarborHostForCosign" in body,
}
for k, v in checks.items():
    print(f"   [{'OK' if v else 'FAIL'}] {k}")
if not all(checks.values()):
    sys.exit("FAIL: assembled monolith failed wrapper checks")
print(f"   assembled {len(body.encode('utf-8'))} bytes; runPaasDeploy calls: {present}")
PY

echo "==> Push monolith to ${JENKINS_NS}/${JPOD}:${REMOTE_DIR}/paas-deploy-stages.groovy"
kexec_i tee "${REMOTE_DIR}/paas-deploy-stages.groovy" < "${WORK}/paas-deploy-stages.groovy" >/dev/null

echo "==> Verify on pod (4 wrapper checks)"
kexec sh -c "
  f=${REMOTE_DIR}/paas-deploy-stages.groovy
  grep -qF 'helm-portable-20260620-cps-split' \"\$f\" && echo '   [OK] helm marker' || { echo '   [FAIL] helm marker'; exit 1; }
  grep -qF 'def runPaasDeploy()' \"\$f\" && echo '   [OK] def runPaasDeploy()' || { echo '   [FAIL] def runPaasDeploy()'; exit 1; }
  tail -1 \"\$f\" | grep -qF 'return this' && echo '   [OK] return this (last line)' || { echo '   [FAIL] return this'; exit 1; }
  grep -qF 'def coerceHarborHostForCosign' \"\$f\" && echo '   [OK] coerceHarborHostForCosign' || { echo '   [FAIL] coerceHarborHostForCosign'; exit 1; }
"

echo ""
echo "OK: monolith fixed on ${JENKINS_NS}/${JPOD}. Trigger a NEW paas-deploy build from the PaaS UI."
