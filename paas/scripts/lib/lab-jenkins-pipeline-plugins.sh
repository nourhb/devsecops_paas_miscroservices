#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:${JENKINS_NODEPORT}}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

load_creds() {
  if [[ -f "${ENV_FILE}" ]]; then
    set -a && source "${ENV_FILE}" && set +a
  fi
  JENKINS_USER="${JENKINS_USERNAME:-${JENKINS_USER:-admin}}"
  JENKINS_TOKEN="${JENKINS_API_TOKEN:-${JENKINS_TOKEN:-}}"
  if [[ -z "${JENKINS_TOKEN}" ]]; then
    JENKINS_TOKEN="$(kubectl exec -n "${JENKINS_NS}" jenkins-0 -c jenkins --request-timeout=60s \
      cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r\n' || true)"
  fi
  [[ -n "${JENKINS_TOKEN}" ]] || fail "set JENKINS_API_TOKEN or ensure jenkins-0 pod is running"
  export JENKINS_URL JENKINS_USER JENKINS_TOKEN
}

pipeline_plugins_ready() {
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_TOKEN}" <<'PY'
import base64, json, sys, urllib.error, urllib.request
base, user, token = sys.argv[1:4]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
req = urllib.request.Request(
    f"{base.rstrip('/')}/pluginManager/api/json?depth=1",
    headers={"Authorization": f"Basic {auth}"},
)
try:
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = json.loads(resp.read().decode())
except urllib.error.HTTPError as e:
    print(f"HTTP {e.code}", file=sys.stderr)
    sys.exit(2)
plugins = {p.get("shortName") for p in data.get("plugins", []) if p.get("active")}
need = ("workflow-job", "workflow-cps")
missing = [p for p in need if p not in plugins]
if missing:
    print("missing:" + ",".join(missing))
    sys.exit(1)
print("ready")
PY
}

install_pipeline_plugins() {
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_TOKEN}" <<'PY'
import base64, json, sys, time, urllib.error, urllib.parse, urllib.request
base, user, token = sys.argv[1:4]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
headers = {"Authorization": f"Basic {auth}"}

def call(path, method="GET", data=None, ctype=None, timeout=300):
    h = dict(headers)
    if data is not None:
        h["Content-Type"] = ctype or "text/xml; charset=UTF-8"
    req = urllib.request.Request(f"{base.rstrip('/')}{path}", data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

def crumb():
    code, body = call("/crumbIssuer/api/json")
    if code != 200:
        return {}
    j = json.loads(body)
    return {j["crumbRequestField"]: j["crumb"]}

plugins = (
    "workflow-aggregator",
    "git",
    "credentials-binding",
    "pipeline-utility-steps",
    "timestamper",
)
xml = "<jenkins>" + "".join(f'<install plugin="{p}@latest" />' for p in plugins) + "</jenkins>"
extra = crumb()
code, body = call(
    "/pluginManager/installNecessaryPlugins",
    "POST",
    xml.encode("utf-8"),
    "text/xml; charset=UTF-8",
)
print(f"POST installNecessaryPlugins -> {code}")
if code not in (200, 201, 302):
    print(body[:2000], file=sys.stderr)
    sys.exit(1)

deadline = time.time() + 900
while time.time() < deadline:
    code, body = call("/pluginManager/api/json?depth=1")
    if code == 200:
        data = json.loads(body)
        active = {p.get("shortName") for p in data.get("plugins", []) if p.get("active")}
        if "workflow-job" in active and "workflow-cps" in active:
            print("plugins active: workflow-job, workflow-cps")
            break
    time.sleep(10)
else:
    print("timeout waiting for workflow plugins", file=sys.stderr)
    sys.exit(1)

code, body = call("/updateCenter/api/json?tree=jobs[status,name]")
if code == 200 and "jobs" in body:
    print("updateCenter jobs present — waiting for idle")
    for _ in range(90):
        code, body = call("/updateCenter/api/json?tree=jobs[status,name]")
        if code == 200:
            jobs = json.loads(body).get("jobs") or []
            if not jobs or all(j.get("status") in (None, "SUCCESS", "FAILURE") for j in jobs):
                break
        time.sleep(5)

code, _ = call("/safeRestart", "POST", b"", "application/x-www-form-urlencoded", timeout=60)
print(f"POST safeRestart -> {code}")
PY
}

wait_jenkins_api() {
  local n=0 code
  until [[ "${n}" -gt 60 ]]; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
      -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${JENKINS_URL}/api/json" 2>/dev/null || echo 000)"
    [[ "${code}" == "200" ]] && { ok "Jenkins API ready after plugin install (HTTP ${code})"; return 0; }
    n=$((n + 1))
    echo "  waiting Jenkins API (${n}/60) HTTP ${code}…"
    sleep 10
  done
  fail "Jenkins API not ready at ${JENKINS_URL}"
}

main() {
  command -v python3 >/dev/null 2>&1 || fail "python3 required"
  command -v curl >/dev/null 2>&1 || fail "curl required"
  load_creds

  echo "=============================================="
  echo " Jenkins Pipeline plugins (workflow-aggregator)"
  echo "=============================================="

  if pipeline_plugins_ready 2>/dev/null; then
    ok "Pipeline plugins already installed"
    exit 0
  fi

  echo "==> Installing workflow-aggregator (+ git, credentials-binding)…"
  install_pipeline_plugins || fail "plugin install API failed"
  wait_jenkins_api

  if pipeline_plugins_ready; then
    ok "Pipeline plugins installed"
  else
    fail "plugins still missing after install — open ${JENKINS_URL}/pluginManager/installed"
  fi
}

main "$@"
