#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE_DIR="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
REMOTE_STAGES="${JENKINS_STAGES_REMOTE_PATH:-${REMOTE_DIR}/paas-deploy-stages.groovy}"
DT_MARKER="${DT_STAGES_MARKER:-helm-portable-20260620-cps-split}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
KTO="${KUBECTL_REQUEST_TIMEOUT:-120s}"
source "${SCRIPT_DIR}/lab-jenkins-pod.sh"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
BUNDLE_FILES=(
  paas-deploy-load-h1.groovy
  paas-deploy-load-h2.groovy
  paas-deploy-load-h3.groovy
  paas-deploy-stages-vars.groovy
  paas-deploy-stages-p1.groovy
  paas-deploy-stages-p2.groovy
  paas-deploy-stages-p3.groovy
  paas-deploy-stages.groovy
)
STAGES_P3="${REMOTE_DIR}/paas-deploy-stages-p3.groovy"

kubectl_api_ok() {
  kubectl get --raw=/healthz --request-timeout=15s >/dev/null 2>&1
}

discover_jenkins_deploy() {
  jenkins_discover_ns
}

install_one_file() {
  local ns="$1"
  local local_path="$2"
  local remote_path="$3"
  local bytes
  bytes="$(wc -c < "${local_path}" | tr -d ' ')"
  echo "==> ${local_path##*/} → ${remote_path} (${bytes} bytes)"
  jenkins_exec_i "${ns}" tee "${remote_path}" < "${local_path}" >/dev/null
}

verify_remote_bundle() {
  local ns="$1"
  local f remote
  for f in "${BUNDLE_FILES[@]}"; do
    remote="${REMOTE_DIR}/${f}"
    jenkins_exec "${ns}" grep -qF "${DT_MARKER}" "${remote}" 2>/dev/null || return 1
  done
  jenkins_exec "${ns}" grep -qE 'def runPaasDeploy(\(\)| = \{)' "${STAGES_P3}" 2>/dev/null \
    && jenkins_exec "${ns}" grep -qF 'runPaasDeploySteps9_12' "${STAGES_P3}" 2>/dev/null \
    && jenkins_exec "${ns}" sh -c "test \$(grep -c 'def runPaasDeploy()' '${STAGES_P3}') -eq 1" 2>/dev/null \
    && ! jenkins_exec "${ns}" grep -qE '^runPaasDeploy\(\)[[:space:]]*$' "${STAGES_P3}" 2>/dev/null
}

print_manual_install() {
  local jpod
  jpod="$(jenkins_pod_name "${JENKINS_NS}" 2>/dev/null || echo jenkins-0)"
  echo ""
  echo "Manual install (each file):"
  for f in "${BUNDLE_FILES[@]}"; do
    echo "  kubectl exec -i -n ${JENKINS_NS} ${jpod} -c ${JENKINS_CONTAINER} -- \\"
    echo "    tee ${REMOTE_DIR}/${f} < ${RENDER_DIR}/${f}"
  done
}

mkdir -p "${RENDER_DIR}"
if grep -qF '"def runPaasDeploy = {\\n"' "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" 2>/dev/null \
  || grep -qF 'f"def {name} = {{\\n{chunk}}}\n"' "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" 2>/dev/null; then
  echo "==> Auto-patch render-loadable-stages.py (closure syntax breaks Jenkins load())"
  if [[ -x "${SCRIPT_DIR}/fix-cps-load-method-syntax.sh" ]]; then
    bash "${SCRIPT_DIR}/fix-cps-load-method-syntax.sh" --patch-only
  else
    python3 <<'PY'
from pathlib import Path
p = Path("paas/jenkins/render-loadable-stages.py")
t = p.read_text(encoding="utf-8")
t = t.replace('runPaasDeployEnvInit = {', 'runPaasDeployEnvInit() {')
t = t.replace('f"def {name} = {{\\n{chunk}}}\n"', 'f"def {name}() {{\\n{chunk}}}\n"')
t = t.replace('"def runPaasDeploy = {\\n"', '"def runPaasDeploy() {\\n"')
if 'CPS_LOAD_METHOD_SYNTAX=20260626' not in t:
    t = t.replace(
        'return f"// STAGES_BUNDLE_VERSION={BUNDLE_MARKER}\\n"',
        'return f"// STAGES_BUNDLE_VERSION={BUNDLE_MARKER}\\n// CPS_LOAD_METHOD_SYNTAX=20260626\\n"',
    )
p.write_text(t, encoding="utf-8")
print("OK: patched render-loadable-stages.py inline")
PY
  fi
fi
python3 "${REPO_ROOT}/paas/jenkins/split-cps-hotspots.py" 2>/dev/null || true
python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" --out-dir "${RENDER_DIR}" || {
  echo "ERROR: render-loadable-stages.py failed" >&2
  exit 1
}

bash "${SCRIPT_DIR}/fix-p3-no-self-invoke.sh" 2>/dev/null || python3 - "${RENDER_DIR}/paas-deploy-stages-p3.groovy" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
if not p.is_file():
    sys.exit(0)
t = p.read_text(encoding="utf-8")

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
p.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

bash "${SCRIPT_DIR}/ensure-p3-orchestrator.sh" "${RENDER_DIR}/paas-deploy-stages-p3.groovy"

for f in "${BUNDLE_FILES[@]}"; do
  [[ -f "${RENDER_DIR}/${f}" ]] || { echo "ERROR: missing ${RENDER_DIR}/${f}" >&2; exit 1; }
  if ! grep -qF "${DT_MARKER}" "${RENDER_DIR}/${f}"; then
    echo "ERROR: ${f} missing ${DT_MARKER}" >&2
    exit 1
  fi
done

if ! grep -qF 'def runPaasDeploy()' "${RENDER_DIR}/paas-deploy-stages-p3.groovy"; then
  echo "ERROR: stages-p3 missing runPaasDeploy orchestrator after repair" >&2
  exit 1
fi

stages="${RENDER_DIR}/paas-deploy-stages.groovy"
if ! grep -qF 'def runPaasDeploy()' "${stages}"; then
  echo "ERROR: paas-deploy-stages.groovy missing def runPaasDeploy()" >&2
  exit 1
fi
if ! grep -qF 'return this' "${stages}"; then
  echo "ERROR: paas-deploy-stages.groovy missing return this (required for paas=load)" >&2
  exit 1
fi
if ! grep -qF 'stage("Step 12 —' "${RENDER_DIR}/paas-deploy-stages.groovy"; then
  echo "ERROR: stages file missing Step 12" >&2
  exit 1
fi
cp "${RENDER_DIR}/paas-deploy-stages.groovy" "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy"
echo "==> Rendered CPS-split bundle under ${RENDER_DIR}"
ls -la "${RENDER_DIR}"/paas-deploy-*.groovy

if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl missing — bundle on disk only at ${RENDER_DIR}" >&2
  exit 0
fi
if [[ "${RENDER_ONLY:-0}" == "1" ]]; then
  echo "OK: render-only — bundle at ${RENDER_DIR}"
  exit 0
fi
if ! kubectl_api_ok; then
  echo "WARN: k8s API failed — bundle saved at ${RENDER_DIR}" >&2
  print_manual_install
  exit 1
fi
ns="$(discover_jenkins_deploy || true)"
if [[ -z "${ns}" ]]; then
  echo "ERROR: no Jenkins pod found (expected StatefulSet jenkins-0 in cicd)" >&2
  echo "  Try: bash paas/scripts/lib/install-cps-bundle-jenkins-0.sh" >&2
  print_manual_install
  exit 1
fi
jenkins_exec "${ns}" mkdir -p "${REMOTE_DIR}"
for f in "${BUNDLE_FILES[@]}"; do
  install_one_file "${ns}" "${RENDER_DIR}/${f}" "${REMOTE_DIR}/${f}"
done
verify_remote_bundle "${ns}"
jpod="$(jenkins_pod_name "${ns}")"
echo "OK: CPS-split bundle on ${ns}/${jpod} (${DT_MARKER})"

if [[ "${SKIP_JOB_PATCH:-0}" != "1" ]]; then
  echo "==> Patch paas-deploy job wrapper (multi-load + runPaasDeploy)"
  bash "${SCRIPT_DIR}/patch-jenkins-cps-split-job.sh"
fi
