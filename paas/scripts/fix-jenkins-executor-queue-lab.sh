#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
JOB="${JOB_NAME:-paas-deploy}"

if [[ -f "${ENV_FILE}" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "${ENV_FILE}" 2>/dev/null || true
  set -u
  JENKINS_URL="${JENKINS_PROBE_URL:-${JENKINS_URL}}"
fi

if [[ -z "${JENKINS_USERNAME:-}" || -z "${JENKINS_API_TOKEN:-}" ]]; then
  echo "ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
fi

AUTH=(-u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}")

echo "==> 1. Wait for Jenkins API"
for i in $(seq 1 30); do
  curl -fsS --connect-timeout 5 "${JENKINS_URL}/api/json" >/dev/null 2>&1 && break
  sleep 3
  [[ "${i}" -eq 30 ]] && { echo "FAIL: Jenkins not up at ${JENKINS_URL}"; exit 1; }
done

echo "==> 2. Built-in node / executors"
curl -g -fsS "${AUTH[@]}" "${JENKINS_URL}/computer/api/json?tree=computer[displayName,numExecutors,idleExecutors,busyExecutors]" 2>/dev/null | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d.get('computer',[]):
    print(f\"  {c.get('displayName')}: executors={c.get('numExecutors')} idle={c.get('idleExecutors')} busy={c.get('busyExecutors')}\")
" || echo "WARN: could not read /computer/api/json"

echo "==> 3. Stop stuck ${JOB} builds (needs crumb for POST — plain curl often gets 403)"
python3 <<'PY' "${JENKINS_URL}" "${JOB}" "${JENKINS_USERNAME}" "${JENKINS_API_TOKEN}"
import json, sys, urllib.request, base64
base, job, user, token = sys.argv[1:5]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
headers = {"Authorization": f"Basic {auth}"}

def get(url):
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())

def crumb_headers():
    try:
        j = get(f"{base}/crumbIssuer/api/json")
        return {j["crumbRequestField"]: j["crumb"]}
    except Exception:
        return {}

def post(url):
    h = dict(headers)
    h.update(crumb_headers())
    req = urllib.request.Request(url, method="POST", headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            print(f"  -> {r.status}")
            return True
    except urllib.error.HTTPError as e:
        print(f"  stop failed: HTTP {e.code} {e.reason}")
        return False
    except Exception as e:
        print(f"  stop failed: {e}")
        return False

data = get(f"{base}/job/{job}/api/json?tree=builds[number,building]")
for b in data.get("builds", [])[:20]:
    n = b.get("number")
    if not n or not b.get("building"):
        continue
    print(f"  stopping running #{n}")
    post(f"{base}/job/{job}/{n}/stop")
PY

echo "==> 4. Ensure controller has >=2 executors (Groovy init)"
CRUMB="$(curl -fsS "${AUTH[@]}" "${JENKINS_URL}/crumbIssuer/api/json" | python3 -c "import json,sys; j=json.load(sys.stdin); print(j['crumb'])" 2>/dev/null || true)"
CRUMB_FIELD="$(curl -fsS "${AUTH[@]}" "${JENKINS_URL}/crumbIssuer/api/json" | python3 -c "import json,sys; j=json.load(sys.stdin); print(j['crumbRequestField'])" 2>/dev/null || true)"
GROOVY='import jenkins.model.Jenkins
def j = Jenkins.getInstance()
j.setNumExecutors(Math.max(2, j.getNumExecutors()))
j.save()
println "numExecutors=" + j.getNumExecutors()'

if [[ -n "${CRUMB}" && -n "${CRUMB_FIELD}" ]]; then
  curl -fsS -X POST "${AUTH[@]}" -H "${CRUMB_FIELD}: ${CRUMB}" \
    --data-urlencode "script=${GROOVY}" \
    "${JENKINS_URL}/scriptText" || echo "WARN: scriptText failed (enable script console or set executors in UI)"
else
  echo "WARN: no crumb — set # executors in Manage Jenkins → System Configuration → # of executors = 2"
fi

echo ""
echo "OK. In Jenkins UI: cancel any old 'paas-deploy' builds (×), then Build with Parameters."
echo "Job parameter JENKINS_AGENT_LABEL must be 'built-in' (or empty → defaults to built-in)."
echo "If still stuck: Manage Jenkins → Nodes → Built-In Node → Configure → # of executors = 2"
