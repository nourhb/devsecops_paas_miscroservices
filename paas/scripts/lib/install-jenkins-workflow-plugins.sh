#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:${JENKINS_NODEPORT}}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"

PLUGINS=(
  workflow-aggregator
  git
  credentials-binding
  pipeline-utility-steps
  timestamper
)

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
    JENKINS_TOKEN="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
      cat /run/secrets/additional/chart-admin-password 2>/dev/null | tr -d '\r\n' || true)"
  fi
  [[ -n "${JENKINS_TOKEN}" ]] || fail "set JENKINS_API_TOKEN or ensure ${JPOD} is running"
  export JENKINS_URL JENKINS_USER JENKINS_TOKEN
}

plugins_ready_api() {
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_TOKEN}" <<'PY'
import base64, json, sys, urllib.request
base, user, token = sys.argv[1:4]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
req = urllib.request.Request(
    f"{base.rstrip('/')}/pluginManager/api/json?depth=1",
    headers={"Authorization": f"Basic {auth}"},
)
with urllib.request.urlopen(req, timeout=30) as resp:
    data = json.loads(resp.read().decode())
active = {p.get("shortName") for p in data.get("plugins", []) if p.get("active")}
need = ("workflow-job", "workflow-cps")
if all(p in active for p in need):
    print("ready")
    sys.exit(0)
missing = [p for p in need if p not in active]
print("missing:" + ",".join(missing))
sys.exit(1)
PY
}

install_via_plugin_cli() {
  local plugin_list="${PLUGINS[*]}"

  echo "==> jenkins-plugin-cli inside ${JPOD} (plugins: ${plugin_list})"
  kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=900s -- bash -s -- ${plugin_list} <<'EOS'
set -euo pipefail
PLUGINS=("$@")
CLI=""
for c in jenkins-plugin-cli /usr/bin/jenkins-plugin-cli; do
  if command -v "${c}" >/dev/null 2>&1; then CLI="${c}"; break; fi
done
if [[ -z "${CLI}" && -f /opt/jenkins-plugin-manager/jenkins-plugin-manager.jar ]]; then
  CLI="java -jar /opt/jenkins-plugin-manager/jenkins-plugin-manager.jar"
fi
if [[ -z "${CLI}" ]]; then
  echo "jenkins-plugin-cli not found in image" >&2
  exit 2
fi
echo "[plugin-cli] using: ${CLI}"
${CLI} -d /var/jenkins_home/plugins --verbose --plugins "${PLUGINS[@]}"
EOS
}

install_via_rest() {
  echo "==> pluginManager REST (with CSRF crumb + session cookie)"
  python3 - "${JENKINS_URL}" "${JENKINS_USER}" "${JENKINS_TOKEN}" "${PLUGINS[*]}" <<'PY'
import base64, http.cookiejar, json, sys, time, urllib.error, urllib.request
base, user, token, plugins_s = sys.argv[1:5]
plugins = plugins_s.split()
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))

def call(path, method="GET", data=None, ctype=None):
    h = {"Authorization": f"Basic {auth}"}
    if data is not None:
        h["Content-Type"] = ctype or "text/xml; charset=UTF-8"
    req = urllib.request.Request(f"{base.rstrip('/')}{path}", data=data, headers=h, method=method)
    try:
        with opener.open(req, timeout=300) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

def crumb():
    code, body = call("/crumbIssuer/api/json")
    if code != 200:
        return {}
    j = json.loads(body)
    return {j["crumbRequestField"]: j["crumb"]}

def ready():
    code, body = call("/pluginManager/api/json?depth=1")
    if code != 200:
        return False
    active = {p.get("shortName") for p in json.loads(body).get("plugins", []) if p.get("active")}
    return "workflow-job" in active and "workflow-cps" in active

if ready():
    print("already ready")
    sys.exit(0)

xml = "<jenkins>" + "".join(f'<install plugin="{p}@latest" />' for p in plugins) + "</jenkins>"
extra = crumb()
h = {"Authorization": f"Basic {auth}", "Content-Type": "text/xml; charset=UTF-8"}
h.update(extra)
req = urllib.request.Request(
    f"{base.rstrip('/')}/pluginManager/installNecessaryPlugins",
    data=xml.encode("utf-8"),
    method="POST",
    headers=h,
)
try:
    with opener.open(req, timeout=300) as resp:
        code = resp.status
except urllib.error.HTTPError as e:
    code = e.code
    print(e.read().decode()[:1500], file=sys.stderr)
print(f"installNecessaryPlugins -> {code}")
if code not in (200, 201, 302):
    sys.exit(1)

deadline = time.time() + 900
while time.time() < deadline:
    if ready():
        print("plugins active")
        break
    time.sleep(10)
else:
    print("timeout waiting for plugins", file=sys.stderr)
    sys.exit(1)

extra = crumb()
h = {"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"}
h.update(extra)
req = urllib.request.Request(f"{base.rstrip('/')}/safeRestart", data=b"", method="POST", headers=h)
try:
    with opener.open(req, timeout=60) as resp:
        print(f"safeRestart -> {resp.status}")
except urllib.error.HTTPError as e:
    print(f"safeRestart -> {e.code}")
PY
}

wait_jenkins_up() {
  local n=0 code
  until [[ "${n}" -gt 72 ]]; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
      -u "${JENKINS_USER}:${JENKINS_TOKEN}" "${JENKINS_URL}/api/json" 2>/dev/null || echo 000)"
    if [[ "${code}" == "200" ]] && plugins_ready_api 2>/dev/null; then
      ok "Jenkins API + workflow plugins ready (HTTP ${code})"
      return 0
    fi
    n=$((n + 1))
    echo "  waiting Jenkins + plugins (${n}/72) HTTP ${code}…"
    sleep 10
  done
  fail "Jenkins or workflow plugins not ready at ${JENKINS_URL}"
}

restart_jenkins() {
  echo "==> Restart Jenkins (plugins require restart)"
  kubectl rollout restart "statefulset/jenkins" -n "${JENKINS_NS}" 2>/dev/null || \
    kubectl delete pod -n "${JENKINS_NS}" "${JPOD}" --wait=false 2>/dev/null || true
  kubectl rollout status "statefulset/jenkins" -n "${JENKINS_NS}" --timeout=900s 2>/dev/null || true
}

main() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
  command -v python3 >/dev/null 2>&1 || fail "python3 required"
  load_creds

  echo "=============================================="
  echo " Install Jenkins workflow plugins"
  echo "=============================================="

  if plugins_ready_api 2>/dev/null; then
    ok "workflow-job + workflow-cps already active"
    exit 0
  fi

  if install_via_plugin_cli; then
    restart_jenkins
  else
    warn "plugin-cli failed — trying REST API"
    install_via_rest || fail "REST plugin install failed"
  fi

  wait_jenkins_up
  ok "Pipeline plugins installed"
}

main "$@"
