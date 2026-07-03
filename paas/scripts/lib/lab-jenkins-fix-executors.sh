#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_USER="${JENKINS_ADMIN_USER:-admin}"
EXECUTORS="${JENKINS_NUM_EXECUTORS:-4}"
JENKINS_URL="http://${NODE_IP}:${JENKINS_NODEPORT}"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

read_token() {
  if [[ -n "${JENKINS_API_TOKEN:-}" ]]; then
    printf '%s' "${JENKINS_API_TOKEN}"
    return 0
  fi
  local env_file="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
  if [[ -f "${env_file}" ]]; then
    local t
    t="$(grep -E '^JENKINS_API_TOKEN=' "${env_file}" | tail -1 | cut -d= -f2- | tr -d '\r"')"
    if [[ -n "${t}" ]]; then
      printf '%s' "${t}"
      return 0
    fi
  fi
  kubectl exec -n "${JENKINS_NS}" jenkins-0 -c jenkins --request-timeout=60s \
    cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r\n'
}

main() {
  command -v python3 >/dev/null 2>&1 || fail "python3 required"
  local token
  token="$(read_token)"
  [[ -n "${token}" ]] || fail "set JENKINS_API_TOKEN or ensure jenkins-0 is running"

  echo "==> jenkins-fix-executors (target ${EXECUTORS} on built-in node)"
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${token}" "${EXECUTORS}" <<'PY'
import base64, json, sys, urllib.error, urllib.parse, urllib.request, http.cookiejar

base, user, token, want = sys.argv[1:5]
want = int(want)
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
headers = {"Authorization": f"Basic {auth}"}

def call(path, data=None, extra=None):
    h = dict(headers)
    if extra:
        h.update(extra)
    if data is not None:
        h["Content-Type"] = "application/x-www-form-urlencoded"
    req = urllib.request.Request(f"{base.rstrip('/')}{path}", data=data, headers=h, method="POST" if data is not None else "GET")
    with opener.open(req, timeout=60) as resp:
        return resp.read().decode("utf-8", "replace")

crumb = json.loads(call("/crumbIssuer/api/json"))
crumb_h = {crumb["crumbRequestField"]: crumb["crumb"]}

def groovy(script: str) -> str:
    body = urllib.parse.urlencode({"script": script}).encode()
    return call("/scriptText", data=body, extra=crumb_h)

before = groovy("""
def c = Jenkins.instance.getComputer('')
println "numExecutors=${c.numExecutors} busy=${c.countBusy()} idle=${c.countIdle()}"
""").strip()
print("before:", before)

groovy(f"""
import jenkins.model.Jenkins
def j = Jenkins.instance
def c = j.getComputer('')
if (c == null) {{
  println 'ERROR: built-in computer not found'
  return
}}
c.setNumExecutors({want})
j.save()
println "set numExecutors={want}"
""")

after = groovy("""
def c = Jenkins.instance.getComputer('')
println "numExecutors=${c.numExecutors} busy=${c.countBusy()} idle=${c.countIdle()}"
""").strip()
print("after:", after)

queue = json.loads(call("/queue/api/json?tree=items[id,why,stuck]"))
items = queue.get("items") or []
if items:
    print(f"queue: {len(items)} item(s)")
    for it in items[:5]:
        print(f"  #{it.get('id')} why={it.get('why')} stuck={it.get('stuck')}")
else:
    print("queue: empty")
PY

  ok "built-in executors set to ${EXECUTORS}"
  echo "If a build was queued, it should start within ~30s. Refresh Jenkins console."
}

main "$@"
