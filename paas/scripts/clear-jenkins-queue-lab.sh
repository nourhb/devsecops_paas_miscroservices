#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
  JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_URL}}"
fi

[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "ERROR: JENKINS_USERNAME / JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
}

for i in $(seq 1 40); do
  curl -g -fsS --connect-timeout 5 "${JENKINS_URL}/api/json" >/dev/null 2>&1 && break
  sleep 5
done

python3 <<PY
import json, os, urllib.request, base64
base = os.environ.get("JENKINS_PROBE_URL", os.environ.get("JENKINS_LAB_LOOPBACK", "http://127.0.0.1:30090")).rstrip("/")
user = os.environ["JENKINS_USERNAME"]
token = os.environ["JENKINS_API_TOKEN"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
h = {"Authorization": f"Basic {auth}"}

def get(url):
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read().decode()

def post_script(script):
    crumb = json.loads(get(f"{base}/crumbIssuer/api/json"))
    h2 = dict(h)
    h2[crumb["crumbRequestField"]] = crumb["crumb"]
    data = urllib.parse.urlencode({"script": script}).encode()
    req = urllib.request.Request(f"{base}/scriptText", data=data, method="POST", headers=h2)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode()

import urllib.parse
groovy = r'''
import jenkins.model.Jenkins
def j = Jenkins.instance
println "=== Computers ==="
j.computers.each { c ->
  println "${c.displayName} name='${c.name}' executors=${c.numExecutors} busy=${c.countBusy()} idle=${c.countIdle()} offline=${c.isOffline()}"
}
println "=== Queue (${j.queue.items.size()} items) ==="
j.queue.items.each { item ->
  println "  cancel: ${item.task.name}"
  item.cancel()
}
j.setNumExecutors(Math.max(2, j.getNumExecutors()))
j.save()
println "=== Done. numExecutors=${j.getNumExecutors()} ==="
'''
print(post_script(groovy))
PY

echo ""
echo "Abort remaining runs in UI (paas-deploy → × on each running build), then:"
echo "  bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "  Build #60 with JENKINS_AGENT_LABEL empty or built-in"
