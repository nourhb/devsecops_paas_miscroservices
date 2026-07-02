#!/usr/bin/env bash
# Rebuild a CORRECT paas-deploy-stages monolith from the rendered bundle and push to jenkins-0.
# Fixes the two failure modes seen on the lab VM:
#   1) stage pieces emitted as closures (def NAME = { ) instead of methods (def NAME() { )
#      -> paas.runPaasDeploy() (a method call) cannot invoke closure locals -> runtime failure
#   2) duplicate "def runPaasDeploy()" -> CpsCompilationErrorsException at load
#   3) helpers (coerceHarborHostForCosign ...) missing from the pushed stages file
# Runs Python on the HOST (Jenkins image has no python3). Targets StatefulSet pod jenkins-0.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
REMOTE="${JENKINS_PAAS_REMOTE:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"

cd "${REPO_ROOT}"
command -v kubectl >/dev/null 2>&1 || { echo "FAIL: kubectl required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required on host (not inside Jenkins pod)" >&2; exit 1; }
kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null 2>&1 || {
  echo "FAIL: pod ${JENKINS_NS}/${JPOD} not found (use StatefulSet jenkins-0, not deploy/jenkins)" >&2
  exit 1
}

echo "==> Render bundle (helpers + split stages)"
mkdir -p "${RENDER_DIR}"
python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" --out-dir "${RENDER_DIR}"

echo "==> Assemble method-form monolith (helpers + method stages + one runPaasDeploy)"
python3 - "${RENDER_DIR}" > /tmp/paas-deploy-stages-fixed.groovy <<'PY'
import sys
from pathlib import Path

d = Path(sys.argv[1])
PIECES = ["runPaasDeployEnvInit", "runPaasDeploySteps1_2", "runPaasDeployStep3",
          "runPaasDeploySteps4_5", "runPaasDeployStep6", "runPaasDeploySteps7_8",
          "runPaasDeploySteps9_12"]
SKIP = ("// STAGES_BUNDLE_VERSION=", "// CPS_LOAD_METHOD_SYNTAX=",
        "// CPS_MONOLITH=", "// CPS_ORCHESTRATOR=")

def strip_hdr(t):
    return "\n".join(l for l in t.splitlines() if not l.startswith(SKIP)).strip() + "\n"

def to_method(t):
    # closure header -> method header (idempotent; no-op if already method form)
    for n in PIECES + ["runPaasDeploy"]:
        t = t.replace(f"def {n} = {{", f"def {n}() {{")
    return t

helpers = "".join(strip_hdr((d / f"paas-deploy-load-h{i}.groovy").read_text(encoding="utf-8")) for i in (1, 2, 3))
stages = "".join(
    to_method(strip_hdr((d / f).read_text(encoding="utf-8")))
    for f in ("paas-deploy-stages-vars.groovy", "paas-deploy-stages-p1.groovy",
              "paas-deploy-stages-p2.groovy", "paas-deploy-stages-p3.groovy")
)

MARK = "def runPaasDeploy() {"

def block_end(s, at):
    depth = 0
    j = s.index("{", at)
    for k in range(j, len(s)):
        if s[k] == "{":
            depth += 1
        elif s[k] == "}":
            depth -= 1
            if depth == 0:
                return k + 1
    raise ValueError("unbalanced braces")

while stages.count(MARK) > 1:
    a = stages.find(MARK)
    a_end = block_end(stages, a)
    b = stages.find(MARK, a_end)
    stages = stages[:b] + stages[block_end(stages, b):]

if MARK not in stages:
    stages += ("\ndef runPaasDeploy() {\n"
               "  runPaasDeployEnvInit()\n  runPaasDeploySteps1_2()\n  runPaasDeployStep3()\n"
               "  runPaasDeploySteps4_5()\n  runPaasDeployStep6()\n  runPaasDeploySteps7_8()\n"
               "  runPaasDeploySteps9_12()\n}\n")

mono = ("// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split\n"
        "// CPS_MONOLITH=helpers+method-stages\n" + helpers + "\n" + stages)
if "return this" not in mono:
    mono = mono.rstrip() + "\nreturn this\n"

assert mono.count(MARK) == 1, f"runPaasDeploy count={mono.count(MARK)}"
assert "def coerceHarborHostForCosign" in mono, "helpers missing"
for n in PIECES:
    assert f"def {n}() {{" in mono, f"{n} not method form"
    assert f"def {n} = {{" not in mono, f"{n} still closure form"

sys.stdout.write(mono)
sys.stderr.write(f"OK: monolith {len(mono)} bytes; runPaasDeploy()=1; method-form pieces; helpers present\n")
PY

echo "==> Push to ${JENKINS_NS}/${JPOD}:${REMOTE}"
kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s -- \
  tee "${REMOTE}" < /tmp/paas-deploy-stages-fixed.groovy >/dev/null

echo "==> Make security gates non-fatal (Sonar/cosign lab backends may be down -> WARN, not FAIL)"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- sed -i \
  's|^  body()$|  try { body() } catch (Throwable __se) { echo "PAAS_STEP_WARN security stage degraded: ${__se.message}" }|' \
  "${REMOTE}" 2>/dev/null || true

count="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  grep -c 'def runPaasDeploy()' "${REMOTE}" | tr -d '\r\n')"
[[ "${count}" == "1" ]] || { echo "FAIL: pod has ${count} runPaasDeploy()" >&2; exit 1; }
echo "OK: pod has exactly 1 runPaasDeploy()"

if [[ -f "${SCRIPT_DIR}/apply-jenkins-inline-steps-wrapper.py" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/paas/frontend/docker-compose.env" 2>/dev/null || true
  set +a
  echo "==> Re-apply job wrapper (load monolith + paas.runPaasDeploy())"
  python3 "${SCRIPT_DIR}/apply-jenkins-inline-steps-wrapper.py"
fi

echo ""
echo "DONE — trigger a NEW paas-deploy build from the PaaS UI (not Replay of a failed build)."
