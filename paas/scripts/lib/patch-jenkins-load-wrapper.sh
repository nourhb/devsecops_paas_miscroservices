#!/usr/bin/env bash
# Patch paas-deploy job config.xml: load() stages then runPaasDeploy() (no Jenkins API needed).
set -euo pipefail
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
REMOTE="${JENKINS_STAGES_REMOTE_PATH:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
JOB_CFG="/var/jenkins_home/jobs/paas-deploy/config.xml"

echo "==> patch-jenkins-load-wrapper (namespace=${JENKINS_NS})"

kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- sh -s <<'EOS'
set -eu
f=/var/jenkins_home/jobs/paas-deploy/config.xml
stages=/var/jenkins_home/paas/paas-deploy-stages.groovy
if [ ! -f "$f" ]; then
  echo "ERROR: missing $f" >&2
  exit 1
fi
if [ ! -f "$stages" ]; then
  echo "ERROR: missing $stages — install stages first" >&2
  exit 1
fi
grep -qF 'def runPaasDeploy = {' "$stages" || {
  echo "ERROR: stages file missing runPaasDeploy closure" >&2
  exit 1
}
if grep -qF 'runPaasDeploy()' "$f"; then
  echo "OK: job config already calls runPaasDeploy()"
  exit 0
fi
cp "$f" "${f}.bak.$(date +%s)"
python3 << 'PY'
from pathlib import Path

p = Path("/var/jenkins_home/jobs/paas-deploy/config.xml")
t = p.read_text(encoding="utf-8")
if "runPaasDeploy()" in t:
    print("OK: already patched")
    raise SystemExit(0)
if "load paasDeployStagesPath" not in t:
    raise SystemExit("ERROR: job script missing load paasDeployStagesPath")
needle = "load paasDeployStagesPath"
repl = "load paasDeployStagesPath\n  runPaasDeploy()"
if needle not in t:
    raise SystemExit("ERROR: could not find load line")
t = t.replace(needle, repl, 1)
closure_check = "def runPaasDeploy = {"
if closure_check not in t and "missing runPaasDeploy closure" not in t:
    marker = "helm-portable-20260619"
    old = f"if (!stagesText.contains('{marker}')) {{"
    if old in t:
        ins = (
            f"if (!stagesText.contains('{closure_check}')) {{\n"
            "    error(\"Stale paas-deploy-stages.groovy (missing runPaasDeploy closure) — reinstall stages\")\n"
            "  }\n"
            f"  {old}"
        )
        t = t.replace(old, ins, 1)
p.write_text(t, encoding="utf-8")
print("OK: patched config.xml — added runPaasDeploy() after load")
PY
grep -c 'runPaasDeploy()' "$f"
EOS

echo "==> Verify"
kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  grep -o 'runPaasDeploy()' "$JOB_CFG" | head -1
echo ""
echo "Done. Trigger a NEW paas-deploy build (not Replay)."
