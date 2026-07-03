#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
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

ensure_fresh_splits_on_pod() {
  local need_refresh=0 f bytes
  for f in "${SPLIT_FILES[@]}"; do
    if ! kexec test -f "${REMOTE_DIR}/${f}" 2>/dev/null; then
      echo "WARN: ${f} missing on pod"
      need_refresh=1
      break
    fi
    if ! kexec grep -qF "${BUNDLE}" "${REMOTE_DIR}/${f}" 2>/dev/null; then
      echo "WARN: ${f} on pod missing ${BUNDLE}"
      need_refresh=1
      break
    fi
  done
  if [[ "${need_refresh}" == "1" ]]; then
    echo "==> Pod split bundle stale — run full CPS fix (render + push + assemble)"
    bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
    exit $?
  fi
}

ensure_fresh_splits_on_pod

echo "==> Pull 7 split files from ${JENKINS_NS}/${JPOD}:${REMOTE_DIR} (1 tar stream — fewer round-trips than 7 separate reads)"
bulk_ok=0
for attempt in 1 2 3; do
  if kexec sh -c "cd '${REMOTE_DIR}' && tar -cf - ${SPLIT_FILES[*]}" > "${WORK}/bundle.tar" 2>/dev/null \
    && [[ -s "${WORK}/bundle.tar" ]] \
    && tar -xf "${WORK}/bundle.tar" -C "${WORK}" 2>/dev/null; then
    bulk_ok=1
    break
  fi
  echo "WARN: bulk tar pull-back attempt ${attempt}/3 failed (flaky kubectl exec on loaded VM) — retrying in 4s"
  sleep 4
done
[[ "${bulk_ok}" == "1" ]] && echo "OK: bulk tar pull-back succeeded" || echo "WARN: bulk tar pull-back failed — falling back to per-file reads"

for f in "${SPLIT_FILES[@]}"; do
  bytes=0
  [[ -f "${WORK}/${f}" ]] && bytes="$(wc -c < "${WORK}/${f}" 2>/dev/null | tr -d ' ')"
  [[ -n "${bytes}" ]] || bytes=0
  if [[ "${bytes}" -eq 0 ]] || ! grep -qF "${BUNDLE}" "${WORK}/${f}" 2>/dev/null; then
    for attempt in 1 2 3 4 5; do
      kexec cat "${REMOTE_DIR}/${f}" > "${WORK}/${f}" 2>/dev/null || true
      bytes="$(wc -c < "${WORK}/${f}" 2>/dev/null | tr -d ' ')"
      [[ -n "${bytes}" ]] || bytes=0
      if [[ "${bytes}" -gt 0 ]] && grep -qF "${BUNDLE}" "${WORK}/${f}" 2>/dev/null; then
        break
      fi
      echo "WARN: ${f} read-back attempt ${attempt}/5 got ${bytes} bytes (flaky kubectl exec on loaded VM) — retrying in 4s"
      sleep 4
    done
  fi
  [[ "${bytes}" -gt 0 ]] || { echo "FAIL: ${f} empty on pod after all attempts — k3s API may be too unstable right now (bash paas/scripts/lab.sh k3s-unstick)" >&2; exit 1; }
  grep -qF "${BUNDLE}" "${WORK}/${f}" || { echo "FAIL: ${f} missing ${BUNDLE} after all attempts" >&2; exit 1; }
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

lines = [ln for ln in body.split("\n")]
lines = [ln for ln in lines if ln.strip() != "return this"]
body = "\n".join(lines).rstrip("\n") + "\n"

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

def dedupe_sonar_rc(text: str) -> str:
    """Stale monoliths may contain old inline scanner + shell-wait Sonar blocks (duplicate def sonarRc)."""
    if "sonar-shell-wait-20260701" in text:
        text = re.sub(
            r"\n\s+def sonarRc = sh\(script: '''#!/bin/bash[\s\S]*?''', returnStatus: true\)\n",
            "\n",
            text,
            count=1,
        )
        if "sonar-checkpoint-poll-20260630" in text:
            start = text.find("sonar-checkpoint-poll-20260630")
            end = text.find("sonar-shell-wait-20260701", start + 1)
            if start >= 0 and end > start:
                line_start = text.rfind("\n", 0, start)
                line_start = 0 if line_start < 0 else line_start + 1
                text = text[:line_start] + text[end:]
        text = re.sub(r"^\s+def sonarRc\s*=.*$\n?", "", text, flags=re.MULTILINE)
    seen_def = 0
    out = []
    for ln in text.split("\n"):
        m = re.match(r"^(\s+)def sonarRc(\s*=.*)$", ln)
        if m:
            seen_def += 1
            if seen_def > 1:
                ln = f"{m.group(1)}sonarRc{m.group(2)}"
        out.append(ln)
    return "\n".join(out)


body = dedupe_sonar_rc(body)
sonar_rc_defs = len(re.findall(r"^\s+def sonarRc\s*=", body, re.MULTILINE))
sonar_wait_defs = len(re.findall(r"^\s+def sonarWaitRc\s*=", body, re.MULTILINE))
if "sonar-shell-wait-20260701" in body:
    if sonar_rc_defs != 0:
        sys.exit(f"FAIL: sonar-shell-wait monolith must have 0 def sonarRc, found {sonar_rc_defs}")
    if sonar_wait_defs != 1:
        sys.exit(f"FAIL: expected exactly 1 def sonarWaitRc, found {sonar_wait_defs}")
elif sonar_rc_defs > 1:
    sys.exit(f"FAIL: expected at most 1 def sonarRc in monolith, found {sonar_rc_defs}")
if sonar_wait_defs > 1:
    sys.exit(f"FAIL: expected at most 1 def sonarWaitRc in monolith, found {sonar_wait_defs}")

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

echo "==> Verify on pod (4 wrapper checks + Sonar compile safety)"
kexec sh -c "
  f=${REMOTE_DIR}/paas-deploy-stages.groovy
  grep -qF 'helm-portable-20260620-cps-split' \"\$f\" && echo '   [OK] helm marker' || { echo '   [FAIL] helm marker'; exit 1; }
  grep -qF 'def runPaasDeploy()' \"\$f\" && echo '   [OK] def runPaasDeploy()' || { echo '   [FAIL] def runPaasDeploy()'; exit 1; }
  tail -1 \"\$f\" | grep -qF 'return this' && echo '   [OK] return this (last line)' || { echo '   [FAIL] return this'; exit 1; }
  grep -qF 'def coerceHarborHostForCosign' \"\$f\" && echo '   [OK] coerceHarborHostForCosign' || { echo '   [FAIL] coerceHarborHostForCosign'; exit 1; }
  if grep -qF 'sonar-shell-wait-20260701' \"\$f\"; then
    rc=\$(grep -c 'def sonarRc' \"\$f\" || true)
    wait=\$(grep -c 'def sonarWaitRc' \"\$f\" || true)
    if [ \"\$rc\" != 0 ] || [ \"\$wait\" != 1 ]; then
      echo \"   [FAIL] Sonar compile safety: def sonarRc=\$rc def sonarWaitRc=\$wait (re-run fix-paas-deploy-cps-split-now.sh)\"
      exit 1
    fi
    echo '   [OK] Sonar sonarWaitRc only (no def sonarRc)'
  fi
"

echo ""
echo "OK: monolith fixed on ${JENKINS_NS}/${JPOD}. Trigger a NEW paas-deploy build from the PaaS UI."
