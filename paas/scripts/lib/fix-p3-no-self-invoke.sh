#!/usr/bin/env bash
# Lab helper script for fix p3 no self invoke
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
REMOTE_P3="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}/paas-deploy-stages-p3.groovy"
RENDER_DIR="${PAAS_RENDER_DIR:-/var/tmp/paas-deploy-bundle}"

sanitize_p3_file() {
  local f="$1"
  python3 - "$f" <<'PY'
import re
import sys
from pathlib import Path

p = Path(sys.argv[1])
t = p.read_text(encoding="utf-8")

def end_of_block(s: str, start: int) -> int:
    depth = 0
    for i in range(start, len(s)):
        c = s[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("unbalanced braces in runPaasDeploy block")

marker = "def runPaasDeploy() {"
while t.count(marker) > 1:
    first = t.find(marker)
    first_end = end_of_block(t, first + len(marker) - 1)
    second = t.find(marker, first_end)
    if second < 0:
        break
    second_end = end_of_block(t, second + len(marker) - 1)
    t = t[:second] + t[second_end:]
    print(f"removed duplicate def runPaasDeploy() at char {second}")

lines = t.splitlines()
while lines and lines[-1].strip() == "":
    lines.pop()
while lines and lines[-1].strip() == "runPaasDeploy()":
    lines.pop()
while lines and lines[-1].strip() == "":
    lines.pop()
out = "\n".join(lines) + "\n"
out = out.replace(
    "// CPS entrypoint: invoked when wrapper load()s this file",
    "// CPS_ORCHESTRATOR=runPaasDeploy-after-all-loads (job wrapper calls runPaasDeploy() — not inside load p3)",
)
if out.count(marker) != 1:
    sys.exit(f"ERROR: p3 must have exactly 1 def runPaasDeploy(), found {out.count(marker)}")
if re.search(r"^runPaasDeploy\(\)\s*$", out, re.M):
    sys.exit("ERROR: p3 still contains runPaasDeploy() call at EOF (wrapper calls it after loads)")
p.write_text(out, encoding="utf-8")
print(f"OK: sanitized {p} (1 def runPaasDeploy())")
PY
}

cd "${REPO_ROOT}"

if [[ -f "${RENDER_DIR}/paas-deploy-stages-p3.groovy" ]]; then
  sanitize_p3_file "${RENDER_DIR}/paas-deploy-stages-p3.groovy"
fi

JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"
if command -v kubectl >/dev/null 2>&1 && kubectl get pod -n "${JENKINS_NS}" "${JPOD}" >/dev/null 2>&1; then
  echo "==> Sanitize p3 on Jenkins pod (${JPOD})"
  kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s -- \
    cat "${REMOTE_P3}" > /tmp/paas-deploy-stages-p3.groovy
  sanitize_p3_file /tmp/paas-deploy-stages-p3.groovy
  kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s -- \
    tee "${REMOTE_P3}" < /tmp/paas-deploy-stages-p3.groovy >/dev/null
  kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s -- \
    tail -4 "${REMOTE_P3}"
fi

echo "OK: p3 no longer self-invokes runPaasDeploy() — wrapper must call it after all loads"
