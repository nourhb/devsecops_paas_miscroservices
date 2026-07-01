#!/usr/bin/env bash
# CPS split: Jenkins load() only promotes def foo() { } methods, not def foo = { } closures.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RENDER="${REPO_ROOT}/paas/jenkins/render-loadable-stages.py"

cd "${REPO_ROOT}"

if [[ ! -f "${RENDER}" ]]; then
  echo "ERROR: missing ${RENDER}" >&2
  exit 1
fi

python3 <<'PY'
from pathlib import Path

p = Path("paas/jenkins/render-loadable-stages.py")
t = p.read_text(encoding="utf-8")
before = t

t = t.replace('runPaasDeployEnvInit = {', 'runPaasDeployEnvInit() {')
t = t.replace('f"def {name} = {{\\n{chunk}}}\n"', 'f"def {name}() {{\\n{chunk}}}\n"')
t = t.replace('"def runPaasDeploy = {\\n"', '"def runPaasDeploy() {\\n"')
if 'CPS_LOAD_METHOD_SYNTAX=20260626' not in t:
    t = t.replace(
        'return f"// STAGES_BUNDLE_VERSION={BUNDLE_MARKER}\\n"',
        'return f"// STAGES_BUNDLE_VERSION={BUNDLE_MARKER}\\n// CPS_LOAD_METHOD_SYNTAX=20260626\\n"',
    )

if t == before:
    if 'def runPaasDeploy() {' in t and 'CPS_LOAD_METHOD_SYNTAX=20260626' in t:
        print("OK: render-loadable-stages.py already has CPS load method syntax")
    else:
        print("ERROR: render-loadable-stages.py patch did not apply — git pull or merge manually", file=__import__("sys").stderr)
        raise SystemExit(1)
else:
    p.write_text(t, encoding="utf-8")
    print("OK: patched render-loadable-stages.py (closure → method syntax for load())")
PY

if [[ "${1:-}" == "--patch-only" ]]; then
  exit 0
fi

echo "==> Re-render + install CPS bundle on Jenkins pod"
bash "${SCRIPT_DIR}/install-jenkins-stages-file.sh"

echo ""
echo "Verify on Jenkins pod:"
echo "  kubectl exec -n cicd deploy/jenkins -- grep -F 'def runPaasDeploy()' /var/jenkins_home/paas/paas-deploy-stages-p3.groovy"
echo "  kubectl exec -n cicd deploy/jenkins -- head -2 /var/jenkins_home/paas/paas-deploy-stages-p3.groovy"
echo ""
echo "Then trigger a NEW paas-deploy build (not Replay)."
