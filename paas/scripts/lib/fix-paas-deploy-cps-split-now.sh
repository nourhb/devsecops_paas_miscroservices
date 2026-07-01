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

# shellcheck source=lab-jenkins-pod.sh
source "${SCRIPT_DIR}/lab-jenkins-pod.sh"

resolve_jenkins_pod() {
  if [[ -n "${JENKINS_POD:-}" ]]; then
    JPOD="${JENKINS_POD}"
    return 0
  fi
  JENKINS_NS="$(jenkins_discover_ns 2>/dev/null || echo "${JENKINS_NS}")"
  export JENKINS_NS
  JPOD="$(jenkins_pod_name "${JENKINS_NS}" 2>/dev/null || true)"
  if [[ -z "${JPOD}" ]]; then
    echo "WARN: no Jenkins pod in ${JENKINS_NS} — running jenkins-recover (helm install if missing)"
    bash "${SCRIPT_DIR}/lab-jenkins-recover.sh" recover || true
    JENKINS_NS="$(jenkins_discover_ns 2>/dev/null || echo cicd)"
    export JENKINS_NS
    JPOD="$(jenkins_pod_name "${JENKINS_NS}" 2>/dev/null || true)"
  fi
  if [[ -z "${JPOD}" ]]; then
    echo "FAIL: no Jenkins pod in cluster — run:" >&2
    echo "  bash paas/scripts/lab.sh jenkins-install" >&2
    echo "  bash paas/scripts/lab.sh jenkins-recover" >&2
    kubectl get pods -A 2>/dev/null | grep -i jenkins || kubectl get pods -n cicd 2>/dev/null || true
    exit 1
  fi
  export JPOD
  echo "OK: Jenkins target ${JENKINS_NS}/${JPOD}"
}

kubectl_retry() {
  local attempt rc
  for attempt in 1 2 3 4 5 6; do
    if kubectl "$@"; then
      return 0
    fi
    rc=$?
    if [[ "${attempt}" -lt 6 ]]; then
      echo "WARN: kubectl failed (attempt ${attempt}/6) — k3s API may be busy; waiting 15s…" >&2
      bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" 2>/dev/null || true
      sleep 15
    fi
  done
  return "${rc}"
}

ensure_k8s_for_jenkins_push() {
  echo "==> 0a/5 k3s API stable (kubectl exec/cp to Jenkins pod)"
  bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || {
    echo "WARN: lab-k3s-ensure failed — continuing with kubectl retries" >&2
  }
  resolve_jenkins_pod
  kubectl_retry get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null \
    || { echo "FAIL: pod ${JENKINS_NS}/${JPOD} not found after recover" >&2; exit 1; }
}

echo "=============================================="
echo " FIX paas-deploy: CPS split → Jenkins pod"
echo "=============================================="

if [[ "${SKIP_HARBOR_FIX_PUSH:-}" != "1" ]] && [[ -f "${SCRIPT_DIR}/fix-harbor-push-now.sh" ]]; then
  echo "==> 0/5 Harbor push RBAC (project + robot + crane probe)"
  bash "${SCRIPT_DIR}/fix-harbor-push-now.sh" || echo "WARN: harbor push fix failed — Step 6 may still 401"
elif [[ "${SKIP_HARBOR_FIX_PUSH:-}" != "1" ]] && [[ -f "${SCRIPT_DIR}/lab-harbor.sh" ]]; then
  echo "==> 0/5 Harbor push path (project + token + crane probe)"
  bash "${SCRIPT_DIR}/lab-harbor.sh" fix-push || echo "WARN: harbor fix-push failed — Step 6 may still 401 until harbor is healthy"
fi

if [[ "${SKIP_SONAR_BOOTSTRAP:-}" != "1" ]] && [[ -f "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" ]]; then
  echo "==> 0b/5 Sonar token (skip heal if UP; else fresh install)"
  if curl -fsS -m 8 "http://${NODE_IP:-192.168.56.129}:${SONAR_NODEPORT:-30900}/api/system/status" 2>/dev/null \
    | grep -q '"status":"UP"'; then
    SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" \
      || echo "WARN: sonar-bootstrap failed"
  else
    echo "WARN: Sonar not UP — skip bootstrap here; run: bash paas/scripts/lab.sh sonarqube"
  fi
  if [[ -f "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" ]]; then
    python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only --force \
      || echo "WARN: Jenkins SONAR_TOKEN param sync skipped"
  fi
fi

if [[ "${SKIP_ZAP_TOOLS:-}" != "1" ]] && [[ -f "${SCRIPT_DIR}/lab-jenkins-zap-tools.sh" ]]; then
  echo "==> 0c/5 Jenkins ZAP tools (kubectl in pod + RBAC for Step 10)"
  bash "${SCRIPT_DIR}/lab-jenkins-zap-tools.sh" || echo "WARN: jenkins-zap-tools failed — Step 10 may skip until re-run"
fi

resolve_jenkins_pod

patch_python_bom_ref_quotes() {
  local f fixed=0
  for f in \
    "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy" \
    "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy"; do
    [[ -f "${f}" ]] || continue
    if grep -q "name:pkg,bom-ref:" "${f}" 2>/dev/null; then
      sed -i "s/name:pkg,bom-ref:/name:pkg,'bom-ref':/g" "${f}"
      echo "OK: patched quoted 'bom-ref' in ${f}"
      fixed=1
    fi
  done
  [[ "${fixed}" -eq 1 ]] || true
}

patch_python_bom_ref_on_pod() {
  kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- sh -c \
    "grep -q \"name:pkg,bom-ref:\" '${REMOTE}/paas-deploy-stages.groovy' 2>/dev/null && \
     sed -i \"s/name:pkg,bom-ref:/name:pkg,'bom-ref':/g\" '${REMOTE}/paas-deploy-stages.groovy' && \
     echo patched || echo already-quoted" 2>/dev/null || true
}

echo "==> 1/5 Render 7-file CPS bundle from paas/jenkins/Jenkinsfile.paas-deploy"
rm -rf "${RENDER}"
mkdir -p "${RENDER}"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
RENDER_PY="${REPO_ROOT}/paas/jenkins/render-loadable-stages.py"
patch_python_bom_ref_quotes
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
  stale_h2="${REPO_ROOT}/paas/jenkins/.render-test/paas-deploy-load-h2.groovy"
  if [[ -f "${stale_h2}" ]] && grep -qF '401 fallback' "${stale_h2}" 2>/dev/null; then
    echo "FAIL: paas/jenkins/.render-test has stale nip-first crane push (401 fallback)" >&2
    echo "  Run: bash paas/scripts/lib/fix-harbor-crane-ip-push-now.sh" >&2
    echo "  Or: rm -rf paas/jenkins/.render-test && git pull && re-run this script" >&2
    exit 1
  fi
  echo "WARN: fresh render failed — using paas/jenkins/.render-test/ (may lack latest Jenkinsfile fixes; rm -rf it after git pull)"
  cp "${REPO_ROOT}/paas/jenkins/.render-test"/paas-deploy-*.groovy "${RENDER}/"
fi

if [[ -f "${RENDER}/paas-deploy-load-h2.groovy" ]] && grep -qF '401 fallback' "${RENDER}/paas-deploy-load-h2.groovy" 2>/dev/null; then
  echo "FAIL: render bundle has nip-first crane push (401 fallback) — stale Jenkinsfile or .render-test" >&2
  echo "  Run: bash paas/scripts/lib/fix-harbor-crane-ip-push-now.sh" >&2
  exit 1
fi
if grep -qF 'primary push ref (IP)' "${JENKINSFILE}" 2>/dev/null; then
  grep -qF 'primary push ref (IP)' "${RENDER}/paas-deploy-load-h2.groovy" 2>/dev/null \
    || { echo "FAIL: Jenkinsfile has IP-first crane but render h2 does not — run fix-harbor-crane-ip-push-now.sh" >&2; exit 1; }
  echo "OK: IP-first Harbor crane push present in rendered h2"
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

if [[ -x "${SCRIPT_DIR}/ensure-p3-orchestrator.sh" ]]; then
  bash "${SCRIPT_DIR}/ensure-p3-orchestrator.sh" "${p3}"
else
  python3 - "${p3}" <<'PY'
import re, sys
from pathlib import Path

p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")
marker = "def runPaasDeploy() {"
orch = """def runPaasDeploy() {
  runPaasDeployEnvInit()
  runPaasDeploySteps1_2()
  runPaasDeployStep3()
  runPaasDeploySteps4_5()
  runPaasDeployStep6()
  runPaasDeploySteps7_8()
  runPaasDeploySteps9_12()
}
// CPS_ORCHESTRATOR=runPaasDeploy-after-all-loads (job wrapper calls runPaasDeploy() — not inside load p3)
"""
t = t.replace("def runPaasDeploy = {", marker)
if marker not in t:
    t = t.rstrip() + "\n\n" + orch
    p.write_text(t if t.endswith("\n") else t + "\n", encoding="utf-8")
    print(f"OK: appended runPaasDeploy orchestrator to {p.name}")
    sys.exit(0)
if t.count(marker) == 1:
    print(f"OK: {p.name} already has runPaasDeploy orchestrator")
    sys.exit(0)

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

first = t.find(marker)
fe = end_of_block(t, first + len(marker) - 1)
rest = t[fe:]
rest = re.sub(
    r"def runPaasDeploy(?:\(\)|\s*=\s*\{)[\s\S]*?(?=\n//|\n def |\Z)",
    "",
    rest,
    count=0,
)
out = t[:fe] + rest
out = re.sub(r"\n{3,}", "\n\n", out).rstrip() + "\n"
if out.count(marker) != 1:
    sys.exit(f"ERROR: could not normalize {p.name} to 1 runPaasDeploy (found {out.count(marker)})")
p.write_text(out, encoding="utf-8")
print(f"OK: deduped runPaasDeploy orchestrator in {p.name}")
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

if grep -qF 'sonar-shell-wait-20260701' "${JENKINSFILE}" 2>/dev/null; then
  shell_render="$(grep -c 'sonar-shell-wait-20260701' "${RENDER}/paas-deploy-stages-p2.groovy" 2>/dev/null || echo 0)"
  if [[ "${shell_render}" != "1" ]]; then
    echo "FAIL: Jenkinsfile has sonar-shell-wait but render p2 does not — git pull && re-run" >&2
    exit 1
  fi
  echo "OK: Sonar shell-wait marker present in rendered p2 (Step 5 — no Groovy sleep)"
elif grep -qF 'sonar-checkpoint-poll-20260630' "${JENKINSFILE}" 2>/dev/null; then
  echo "WARN: Jenkinsfile still has old sonar-checkpoint-poll (Groovy sleep) — git pull for sonar-shell-wait-20260701"
fi

if grep -qF 'nginx-crane-ip-first-20260701' "${JENKINSFILE}" 2>/dev/null; then
  nginx_render="$(grep -c 'nginx-crane-ip-first-20260701' "${RENDER}/paas-deploy-stages-p2.groovy" 2>/dev/null || echo 0)"
  if [[ "${nginx_render}" != "1" ]]; then
    echo "FAIL: Jenkinsfile has nginx-crane-ip-first but render p2 does not — git pull && re-run" >&2
    exit 1
  fi
  echo "OK: nginx-crane-ip-first marker present in rendered p2 (Vite/Angular Step 6)"
fi

if grep -qF 'sonar-auto-rotate-token-20260701' "${JENKINSFILE}" 2>/dev/null; then
  rotate_render="$(grep -c 'sonar-auto-rotate-token-20260701' "${RENDER}/paas-deploy-stages-p2.groovy" 2>/dev/null || echo 0)"
  if [[ "${rotate_render}" != "1" ]]; then
    echo "FAIL: Jenkinsfile has sonar-auto-rotate but render p2 does not — git pull Jenkinsfile.paas-deploy && re-run" >&2
    exit 1
  fi
  echo "OK: Sonar auto-rotate marker present in rendered p2 (Step 5)"
else
  echo "WARN: Jenkinsfile missing sonar-auto-rotate-token-20260701 — git pull or copy from dev machine (Step 5 may fail on stale SONAR_TOKEN)"
fi

if grep -qF 'harbor-ensure-push-token-20260630' "${JENKINSFILE}" 2>/dev/null; then
  harbor_render="$(grep -rc 'harbor-ensure-push-token-20260630' "${RENDER}"/paas-deploy-*.groovy 2>/dev/null | awk -F: '{s+=$2} END {print s+0}')"
  if [[ "${harbor_render}" -lt 1 ]]; then
    echo "FAIL: Jenkinsfile has harbor-ensure-push-token but render bundle does not — git pull && re-run" >&2
    exit 1
  fi
  echo "OK: Harbor ensure-push-token marker present in rendered bundle (Step 6)"
fi

SCA_MARKER='Python BOM from requirements.txt (node — works without python3 on agent)'
if grep -qF "${SCA_MARKER}" "${JENKINSFILE}" 2>/dev/null; then
  sca_render="$(grep -c "${SCA_MARKER}" "${RENDER}/paas-deploy-stages-p2.groovy" 2>/dev/null || echo 0)"
  if [[ "${sca_render}" != "1" ]]; then
    echo "FAIL: Jenkinsfile has Python node SCA but render p2 does not (got ${sca_render}) — git pull Jenkinsfile && re-run" >&2
    exit 1
  fi
  echo "OK: Python node-first SCA marker present in rendered p2 (Step 4)"
fi

echo "==> 2/5 Push 7 split files to ${JENKINS_NS}/${JPOD}:${REMOTE}"
ensure_k8s_for_jenkins_push
kubectl_retry exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=90s -- mkdir -p "${REMOTE}"
for f in paas-deploy-load-h1.groovy paas-deploy-load-h2.groovy paas-deploy-load-h3.groovy \
         paas-deploy-stages-vars.groovy paas-deploy-stages-p1.groovy paas-deploy-stages-p2.groovy \
         paas-deploy-stages-p3.groovy; do
  bytes="$(wc -c < "${RENDER}/${f}" | tr -d ' ')"
  echo "   ${f} (${bytes} bytes)"
  if ! kubectl_retry cp "${RENDER}/${f}" "${JENKINS_NS}/${JPOD}:${REMOTE}/${f}" -c "${JCONTAINER}"; then
    echo "WARN: kubectl cp failed for ${f} — fallback to exec tee"
    kubectl_retry exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=180s \
      -- tee "${REMOTE}/${f}" < "${RENDER}/${f}" >/dev/null
  fi
done

kubectl_retry exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=90s \
  -- grep -qF "${BUNDLE}" "${REMOTE}/paas-deploy-stages-p3.groovy"
p3_on_pod="$(kubectl_retry exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=90s \
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
if kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  -- grep -q '^def projectId' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null; then
  echo "FAIL: monolith has def projectId (broken CPS binding) — re-run assemble" >&2
  exit 1
fi
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

if [[ -f "${SCRIPT_DIR}/sync-harbor-jenkins-job-params.py" ]]; then
  python3 "${SCRIPT_DIR}/sync-harbor-jenkins-job-params.py" || echo "WARN: Harbor job param sync skipped"
fi

echo "==> 5/5 Verify pod monolith + LIVE job"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  sh -c "grep -qF 'return this' '${REMOTE}/paas-deploy-stages.groovy'"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
  sh -c "test \"\$(grep -c 'def runPaasDeploy()' '${REMOTE}/paas-deploy-stages.groovy' | tr -d '\\r')\" = 1"
echo "OK: pod monolith verified (return this + 1× runPaasDeploy)"
if grep -qF 'sonar-shell-wait-20260701' "${JENKINSFILE}" 2>/dev/null; then
  shell_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
    grep -c 'sonar-shell-wait-20260701' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${shell_pod}" == "1" ]]; then
    echo "OK: Sonar shell-wait marker on pod monolith"
  else
    echo "FAIL: pod monolith missing sonar-shell-wait (got ${shell_pod}) — abort before deploy" >&2
    exit 1
  fi
elif grep -qF 'sonar-checkpoint-poll-20260630' "${JENKINSFILE}" 2>/dev/null; then
  echo "WARN: pod still has old sonar-checkpoint-poll — git pull Jenkinsfile and re-run this script"
fi
if grep -qF 'sonar-auto-rotate-token-20260701' "${JENKINSFILE}" 2>/dev/null; then
  rotate_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
    grep -c 'sonar-auto-rotate-token-20260701' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${rotate_pod}" == "1" ]]; then
    echo "OK: Sonar auto-rotate marker on pod monolith"
  else
    echo "FAIL: pod monolith missing sonar-auto-rotate-token (got ${rotate_pod}) — abort before deploy" >&2
    exit 1
  fi
fi
if grep -qF 'harbor-ensure-push-token-20260630' "${JENKINSFILE}" 2>/dev/null; then
  harbor_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
    grep -c 'harbor-ensure-push-token-20260630' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${harbor_pod}" == "1" ]]; then
    echo "OK: Harbor ensure-push-token marker on pod monolith"
  else
    echo "FAIL: pod monolith missing harbor-ensure-push-token (got ${harbor_pod}) — abort before deploy" >&2
    exit 1
  fi
fi
if grep -qF 'Python BOM from requirements.txt (node' "${JENKINSFILE}" 2>/dev/null; then
  sca_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
    grep -c 'Python BOM from requirements.txt (node' "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${sca_pod}" == "1" ]]; then
    echo "OK: Python node-first SCA marker on pod monolith"
  else
    echo "FAIL: pod monolith missing Python node SCA (got ${sca_pod}) — abort before deploy" >&2
    exit 1
  fi
  bomref_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
    grep -c "'bom-ref':" "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
  if [[ "${bomref_pod}" -ge 1 ]]; then
    echo "OK: Python SCA bom-ref quoted (Node object literal) on pod monolith"
  else
    echo "WARN: pod monolith missing quoted 'bom-ref' (got ${bomref_pod}) — patching live groovy"
    patch_python_bom_ref_quotes
    patch_python_bom_ref_on_pod
    bomref_pod="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s -- \
      grep -c "'bom-ref':" "${REMOTE}/paas-deploy-stages.groovy" 2>/dev/null | tr -d '\r\n' || echo 0)"
    if [[ "${bomref_pod}" -ge 1 ]]; then
      echo "OK: Python SCA bom-ref quoted after live patch"
    else
      echo "FAIL: pod monolith still missing quoted 'bom-ref' (got ${bomref_pod}) — abort before deploy" >&2
      exit 1
    fi
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
