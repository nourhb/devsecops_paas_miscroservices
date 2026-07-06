#!/usr/bin/env bash
# Lab helper script for ensure p3 orchestrator
set -euo pipefail
P3="${1:?usage: ensure-p3-orchestrator.sh <path-to-paas-deploy-stages-p3.groovy>}"
[[ -f "${P3}" ]] || { echo "ERROR: missing ${P3}" >&2; exit 1; }

python3 - "${P3}" <<'PY'
import re
import sys
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

count = t.count(marker)
if count == 1:
    if not t.rstrip().endswith("}"):
        pass
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
