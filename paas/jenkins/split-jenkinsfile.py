#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parent
main = root / "Jenkinsfile.paas-deploy"
text = main.read_text(encoding="utf-8")
lines = text.splitlines(keepends=True)
start = next(i for i, line in enumerate(lines) if line.startswith("def runPaasDeploy = {"))
end = next(i for i in range(len(lines) - 1, -1, -1) if lines[i].strip() == "}" and i > 3000)
stages = "".join(lines[start + 1 : end])
(root / "Jenkinsfile.paas-deploy-stages.groovy").write_text(stages, encoding="utf-8")
helpers = "".join(lines[:start])
wrapper = """
def paasDeployStagesPath = '/var/jenkins_home/paas/paas-deploy-stages.groovy'

if (!agentLabel || agentLabel == 'built-in') {
  println "[paas] node: default Built-In Node (agentLabel=${agentLabel ?: 'empty'})"
  node {
    if (!fileExists(paasDeployStagesPath)) {
      error("Missing ${paasDeployStagesPath} — run: bash paas/scripts/lab.sh jenkins")
    }
    load paasDeployStagesPath
  }
} else {
  println "[paas] node: agentLabel=${agentLabel}"
  node(agentLabel) {
    if (!fileExists(paasDeployStagesPath)) {
      error("Missing ${paasDeployStagesPath} — run: bash paas/scripts/lab.sh jenkins")
    }
    load paasDeployStagesPath
  }
}
"""
main.write_text(helpers + wrapper, encoding="utf-8")
print(f"OK split: helpers={start} lines, stages={len(stages.splitlines())} lines")
