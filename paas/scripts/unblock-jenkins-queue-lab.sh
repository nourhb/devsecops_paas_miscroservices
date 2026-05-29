#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
BASE="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
NS="${JENKINS_NS:-cicd}"

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

echo "==> 1. Queue + computers"
curl -g -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${BASE}/queue/api/json?depth=1" | python3 -m json.tool || true
curl -g -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${BASE}/computer/api/json?tree=computer[displayName,numExecutors,idleExecutors,busyExecutors,offline]" \
  | python3 -m json.tool || true

echo "==> 2. Cancel each queued item (needs crumb)"
python3 <<PY
import json, os, urllib.request, base64, urllib.parse, sys
base = os.environ.get("JENKINS_PROBE_URL", os.environ.get("BASE", "http://127.0.0.1:30090")).rstrip("/")
user = os.environ["JENKINS_USERNAME"]
token = os.environ["JENKINS_API_TOKEN"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
h = {"Authorization": f"Basic {auth}"}

def req(url, method="GET", data=None):
    r = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp:
            return resp.status, resp.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

_, body = req(f"{base}/crumbIssuer/api/json")
crumb = json.loads(body)
h[crumb["crumbRequestField"]] = crumb["crumb"]

_, qbody = req(f"{base}/queue/api/json?depth=1")
q = json.loads(qbody)
ids = [it.get("id") for it in q.get("items", []) if it.get("id") is not None]
if not ids:
    print("queue already empty")
    sys.exit(0)
for iid in ids:
    code, rb = req(f"{base}/queue/cancelItem?id={iid}", method="POST")
    print(f"cancelItem id={iid} -> HTTP {code}")
    if code >= 400:
        print(rb[:500])
PY

echo "==> 3. Stop running paas-deploy builds (crumb)"
python3 <<PY
import json, os, urllib.request, base64, sys
base = os.environ.get("JENKINS_PROBE_URL", os.environ.get("BASE", "http://127.0.0.1:30090")).rstrip("/")
job = "paas-deploy"
user = os.environ["JENKINS_USERNAME"]
token = os.environ["JENKINS_API_TOKEN"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
h = {"Authorization": f"Basic {auth}"}

def open_json(url):
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read().decode())

def post(url):
    crumb = open_json(f"{base}/crumbIssuer/api/json")
    h2 = dict(h)
    h2[crumb["crumbRequestField"]] = crumb["crumb"]
    req = urllib.request.Request(url, method="POST", headers=h2)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            print(f"  OK {r.status} {url}")
    except urllib.error.HTTPError as e:
        print(f"  HTTP {e.code} {url}")

for b in open_json(f"{base}/job/{job}/api/json?tree=builds[number,building]").get("builds", [])[:25]:
    if b.get("building"):
        post(f"{base}/job/{job}/{b['number']}/stop")
PY

echo "==> 4. Queue after cancel"
curl -g -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${BASE}/queue/api/json?tree=items[why]" | python3 -m json.tool || true

QCOUNT="$(curl -g -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${BASE}/queue/api/json?tree=items[why]" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('items',[])))" 2>/dev/null || echo 1)"

if [[ "${QCOUNT}" != "0" ]]; then
  echo "==> 5. Queue still blocked — restart Jenkins pod (lab nuclear option)"
  kubectl rollout restart deployment/jenkins -n "${NS}"
  kubectl rollout status deployment/jenkins -n "${NS}" --timeout=300s
  for i in $(seq 1 40); do
    curl -g -fsS --connect-timeout 5 "${BASE}/api/json" >/dev/null 2>&1 && break
    sleep 5
  done
  echo "After restart: abort any running paas-deploy in UI, then one new build only."
fi

echo ""
echo "Done. Confirm items: [] then Build #60 from Jenkins UI."
