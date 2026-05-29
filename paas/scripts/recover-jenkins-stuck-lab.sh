#!/usr/bin/env bash
# Unstick Jenkins when builds wait forever on "Waiting for next available executor"
# or Step 3 holds the only executor for hours. Run on lab VM as master.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
BASE="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
JOB="${JOB_NAME:-paas-deploy}"

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
  BASE="${JENKINS_PROBE_URL:-${BASE}}"
fi

[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "ERROR: JENKINS_USERNAME / JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
}

export JENKINS_PROBE_URL="${BASE}"
export JENKINS_USERNAME JENKINS_API_TOKEN

echo "==> 0. Hard reset Jenkins pod (frees zombie executors when API stop/script returns 403)"
kubectl rollout restart deployment/jenkins -n "${JENKINS_NS:-cicd}"
kubectl rollout status deployment/jenkins -n "${JENKINS_NS:-cicd}" --timeout=600s
echo "Wait 60s for Jenkins to finish plugin init…"
sleep 60

echo "==> 1. Wait for Jenkins API at ${BASE}"
for i in $(seq 1 40); do
  curl -fsS --connect-timeout 5 "${BASE}/api/json" >/dev/null 2>&1 && break
  echo "  waiting (${i}/40)…"
  sleep 5
  [[ "${i}" -eq 40 ]] && { echo "FAIL: Jenkins not up"; exit 1; }
done
echo "OK"

echo "==> 2. Clear queue + set 2 executors (Script Console)"
python3 <<'PY'
import json, os, urllib.request, base64, urllib.parse

base = os.environ["JENKINS_PROBE_URL"].rstrip("/")
user = os.environ["JENKINS_USERNAME"]
token = os.environ["JENKINS_API_TOKEN"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
h = {"Authorization": f"Basic {auth}"}

def get(url):
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=90) as r:
        return r.read().decode()

def post_script(script):
    crumb = json.loads(get(f"{base}/crumbIssuer/api/json"))
    h2 = dict(h)
    h2[crumb["crumbRequestField"]] = crumb["crumb"]
    data = urllib.parse.urlencode({"script": script}).encode()
    req = urllib.request.Request(f"{base}/scriptText", data=data, method="POST", headers=h2)
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read().decode()

groovy = r"""
import jenkins.model.Jenkins
def j = Jenkins.instance
j.computers.each { c ->
  println "computer ${c.displayName} executors=${c.numExecutors} busy=${c.countBusy()} idle=${c.countIdle()}"
}
println "queue items before: ${j.queue.items.size()}"
j.queue.items.each { it.cancel() }
j.setNumExecutors(2)
j.save()
println "numExecutors=${j.getNumExecutors()} queue after: ${j.queue.items.size()}"
"""
print(post_script(groovy))
PY

echo "==> 3. Stop all running ${JOB} builds"
python3 <<'PY'
import json, os, sys, urllib.request, base64

base = os.environ["JENKINS_PROBE_URL"].rstrip("/")
job = os.environ.get("JOB_NAME", "paas-deploy")
user = os.environ["JENKINS_USERNAME"]
token = os.environ["JENKINS_API_TOKEN"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
h = {"Authorization": f"Basic {auth}"}

def get(url):
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

def post(url):
    crumb = get(f"{base}/crumbIssuer/api/json")
    h2 = dict(h)
    h2[crumb["crumbRequestField"]] = crumb["crumb"]
    req = urllib.request.Request(url, method="POST", headers=h2)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code

data = get(f"{base}/job/{job}/api/json?tree=builds[number,building]")
stopped = 0
for b in data.get("builds", []):
    n = b.get("number")
    if n and b.get("building"):
        code = post(f"{base}/job/{job}/{n}/stop")
        print(f"  stop #{n} -> HTTP {code}")
        stopped += 1
if not stopped:
    print("  no running builds")
PY

echo "==> 4. Env hints (agent label + no inline sync overwrite)"
upsert() {
  local k="$1" v="$2"
  if grep -q "^${k}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${k}=.*|${k}=${v}|" "${ENV_FILE}"
  else
    echo "${k}=${v}" >> "${ENV_FILE}"
  fi
}
upsert JENKINS_AGENT_LABEL ""
upsert JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"
echo "  JENKINS_AGENT_LABEL= (empty → node{} on built-in)"
echo "  JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false"

echo "==> 5. Sync frontend env"
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"

echo ""
echo "=== DONE ==="
echo "1. In Jenkins UI: confirm no blue 'running' builds on paas-deploy (× if any)."
echo "2. In PaaS: do NOT click Deploy multiple times. One trigger only."
echo "3. Trigger ONE new build (will be #69+). Step 3 can take 30–90 min — that is normal."
echo "4. Watch: curl -fsS -u USER:TOKEN ${BASE}/job/${JOB}/lastBuild/consoleText | tail -20"
echo ""
echo "Optional faster lab build (skips heavy Step 3 npm): set JENKINS_PAAS_FAST_PIPELINE=true"
echo "  then sync env — use only to unblock; set false again for full security steps."
