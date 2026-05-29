#!/usr/bin/env python3
"""Lab Jenkins: 2 executors, clear queue, stop running builds, disable concurrent paas-deploy."""
from __future__ import annotations

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_ENV = REPO_ROOT / "paas" / "frontend" / "docker-compose.env"
JOB = os.environ.get("JOB_NAME", "paas-deploy")

GROOVY = r"""
import jenkins.model.Jenkins

def j = Jenkins.instance
println "=== Before ==="
j.computers.each { c ->
  println "computer ${c.displayName} name='${c.name}' executors=${c.numExecutors} busy=${c.countBusy()} idle=${c.countIdle()}"
}
println "queue=${j.queue.items.size()}"

j.setNumExecutors(2)
j.computers.each { c ->
  if (c.name == "" || c.name == "built-in" || c.displayName?.contains("Built-In")) {
    c.setNumExecutors(2)
  }
}

def job = j.getItemByFullName(""" + f'"{JOB}"' + r""")
if (job != null) {
  job.setConcurrentBuild(false)
  def stopped = []
  job.builds.findAll { it.isBuilding() }.each { b ->
    try {
      b.doStop()
      stopped << b.number
    } catch (Exception e) {
      println "WARN stop #${b.number}: ${e.message}"
    }
  }
  println "stopped builds: ${stopped}"
  job.save()
} else {
  println "WARN: job not found"
}

j.queue.items.each { it.cancel() }
j.save()

println "=== After ==="
println "numExecutors=${j.getNumExecutors()} queue=${j.queue.items.size()}"
j.computers.each { c ->
  println "computer ${c.displayName} executors=${c.numExecutors} busy=${c.countBusy()} idle=${c.countIdle()}"
}
"""


def load_env(path: Path) -> None:
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        k = k.strip()
        if k and k not in os.environ:
            os.environ[k] = v


def main() -> int:
    load_env(DEFAULT_ENV)
    base = os.environ.get("JENKINS_PROBE_URL", os.environ.get("JENKINS_LAB_LOOPBACK", "http://127.0.0.1:30090")).rstrip("/")
    user = os.environ.get("JENKINS_USERNAME") or os.environ.get("JENKINS_USER") or ""
    token = os.environ.get("JENKINS_API_TOKEN") or os.environ.get("JENKINS_TOKEN") or ""
    if not user or not token:
        print("ERROR: JENKINS_USERNAME / JENKINS_API_TOKEN in docker-compose.env", file=sys.stderr)
        return 1

    auth = base64.b64encode(f"{user}:{token}".encode()).decode()
    headers = {"Authorization": f"Basic {auth}"}

    def get(url: str) -> tuple[int, str]:
        req = urllib.request.Request(url, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")

    code, _ = get(f"{base}/api/json")
    if code != 200:
        print(f"ERROR: Jenkins API {code} at {base}", file=sys.stderr)
        return 1

    code, crumb_body = get(f"{base}/crumbIssuer/api/json")
    if code != 200:
        print(f"ERROR: crumbIssuer HTTP {code} — need admin or RunScripts permission", file=sys.stderr)
        return 1
    crumb = json.loads(crumb_body)
    post_headers = dict(headers)
    post_headers[crumb["crumbRequestField"]] = crumb["crumb"]
    data = urllib.parse.urlencode({"script": GROOVY}).encode()
    req = urllib.request.Request(f"{base}/scriptText", data=data, method="POST", headers=post_headers)
    try:
        with urllib.request.urlopen(req, timeout=180) as resp:
            print(resp.read().decode("utf-8", "replace"))
            return 0
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        print(f"ERROR: scriptText HTTP {e.code}", file=sys.stderr)
        print(body[:2000], file=sys.stderr)
        print("\nUse admin API token in docker-compose.env (JENKINS_USERNAME=admin).", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
