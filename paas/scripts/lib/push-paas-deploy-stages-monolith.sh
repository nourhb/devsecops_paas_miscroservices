#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"
REMOTE="/var/jenkins_home/paas/paas-deploy-stages.groovy"

cd "${REPO_ROOT}"
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required on host" >&2; exit 1; }
kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null 2>&1 || {
  echo "ERROR: pod ${JENKINS_NS}/${JPOD} not found" >&2
  exit 1
}

echo "==> Render bundle"
mkdir -p "${RENDER_DIR}"
python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" --out-dir "${RENDER_DIR}"

echo "==> Assemble monolith (h1+h2+h3+vars+p1+p2+p3 — exactly one runPaasDeploy)"
python3 <<PY
from pathlib import Path
d = Path("${RENDER_DIR}")

def strip_header(text: str) -> str:
    lines = []
    for line in text.splitlines():
        if line.startswith("// STAGES_BUNDLE_VERSION=") or line.startswith("// CPS_LOAD_METHOD_SYNTAX="):
            continue
        if line.startswith("// CPS_MONOLITH="):
            continue
        lines.append(line)
    return "\n".join(lines).strip() + "\n"

parts = [strip_header((d / n).read_text(encoding="utf-8")) for n in (
    "paas-deploy-load-h1.groovy",
    "paas-deploy-load-h2.groovy",
    "paas-deploy-load-h3.groovy",
    "paas-deploy-stages-vars.groovy",
    "paas-deploy-stages-p1.groovy",
    "paas-deploy-stages-p2.groovy",
    "paas-deploy-stages-p3.groovy",
)]
out = "".join(parts)
import re
pat = re.compile(r"def runPaasDeploy\(\)\s*\{[^{}]*\}\n?")
matches = list(pat.finditer(out))
for m in reversed(matches[1:]):
    out = out[: m.start()] + out[m.end() :]
    print(f"OK: removed duplicate runPaasDeploy at offset {m.start()}")
if "return this" not in out:
    out = out.rstrip() + "\nreturn this\n"
count = out.count("def runPaasDeploy()")
if count != 1:
    raise SystemExit(f"ERROR: expected 1 def runPaasDeploy(), found {count}")
if "helm-portable-20260620-cps-split" not in out:
    out = "// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split\n" + out.lstrip()
(d / "paas-deploy-stages.groovy").write_text(
    "// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split\n"
    "// CPS_MONOLITH=h1+h2+h3+vars+p1+p2+p3\n" + out,
    encoding="utf-8",
)
print(f"OK: monolith {len(out)} bytes; runPaasDeploy()={count}")
PY

echo "==> Push to ${JENKINS_NS}/${JPOD}:${REMOTE}"
kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s -- \
  tee "${REMOTE}" < "${RENDER_DIR}/paas-deploy-stages.groovy" >/dev/null

count="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  grep -c 'def runPaasDeploy()' "${REMOTE}" | tr -d '\r\n')"
[[ "${count}" == "1" ]] || { echo "FAIL: pod has ${count} runPaasDeploy()" >&2; exit 1; }
echo "OK: pod has exactly 1 runPaasDeploy()"

if [[ -f "${SCRIPT_DIR}/apply-jenkins-inline-steps-wrapper.py" ]]; then
  set -a
  source "${REPO_ROOT}/paas/frontend/docker-compose.env" 2>/dev/null || true
  set +a
  echo "==> Re-apply job wrapper"
  python3 "${SCRIPT_DIR}/apply-jenkins-inline-steps-wrapper.py"
fi

echo ""
echo "DONE — trigger a NEW paas-deploy build from PaaS UI (not Replay)."
