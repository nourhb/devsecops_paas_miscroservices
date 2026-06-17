#!/usr/bin/env python3
"""Regenerate Jenkinsfile.paas-deploy-stages.groovy from a monolithic backup only — do not run on split layout."""
from pathlib import Path

root = Path(__file__).resolve().parent
main = root / "Jenkinsfile.paas-deploy"
stages = root / "Jenkinsfile.paas-deploy-stages.groovy"
text = main.read_text(encoding="utf-8")
if "def runPaasDeploy = {" not in text:
    print("SKIP: main Jenkinsfile already uses load wrapper; edit stages file directly")
    raise SystemExit(0)
lines = text.splitlines(keepends=True)
start = next(i for i, line in enumerate(lines) if line.startswith("def runPaasDeploy = {"))
end = next(i for i in range(len(lines) - 1, -1, -1) if lines[i].strip() == "}" and i > start + 10)
body = "".join(lines[start + 1 : end]).rstrip() + "\n"
stages.write_text(body, encoding="utf-8")
print(f"OK wrote {stages} ({len(body.splitlines())} lines)")
