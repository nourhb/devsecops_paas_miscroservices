#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parent
main = (root / "Jenkinsfile.paas-deploy").read_text(encoding="utf-8")
stages = (root / "Jenkinsfile.paas-deploy-stages.groovy").read_text(encoding="utf-8")
lines = main.splitlines(keepends=True)
helpers: list[str] = []
for line in lines:
    if line.startswith("def agentLabel = "):
        break
    helpers.append(line)
vars_lines: list[str] = []
for line in lines:
    if line.startswith("def agentLabel = "):
        vars_lines.append(line)
    elif vars_lines and line.startswith("def paasDeployStagesPath"):
        break
    elif vars_lines:
        vars_lines.append(line)
wrapper = """if (!agentLabel || agentLabel == 'built-in') {
  println "[paas] node: default Built-In Node (agentLabel=${agentLabel ?: 'empty'})"
  node {
    runPaasDeploy()
  }
} else {
  println "[paas] node: agentLabel=${agentLabel}"
  node(agentLabel) {
    runPaasDeploy()
  }
}
"""
mono = (
    "".join(helpers)
    + "".join(vars_lines)
    + "def runPaasDeploy = {\n"
    + stages.rstrip()
    + "\n}\n\n"
    + wrapper
)
(root / "Jenkinsfile.paas-deploy").write_text(mono, encoding="utf-8")
print(f"OK: monolithic Jenkinsfile ({len(mono.splitlines())} lines)")
