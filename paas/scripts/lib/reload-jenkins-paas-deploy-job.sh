#!/usr/bin/env bash
# POST paas-deploy config.xml to Jenkins REST API (cookie+crumb) so builds use the live job definition.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JOB="${JENKINS_JOB_NAME:-paas-deploy}"
JOB_CFG="/var/jenkins_home/jobs/${JOB}/config.xml"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_URL="${JENKINS_URL:-http://${NODE_IP}:30090}"
CPS_MARKER="${PAAS_DEPLOY_STAGES_LOAD_MARKER:-paas-deploy-stages-load-20260620-cps-split}"
TMP_CFG="${TMP_CFG:-/tmp/paas-deploy-config.xml}"

load_jenkins_creds() {
  if [[ -f "${ENV_FILE}" ]]; then
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ "${line}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
      case "${line%%=*}" in
        JENKINS_USERNAME|JENKINS_API_TOKEN|JENKINS_USER|JENKINS_TOKEN|JENKINS_BASE_URL|JENKINS_PROBE_URL)
          export "${line}"
          ;;
      esac
    done < "${ENV_FILE}"
  fi
  [[ -z "${JENKINS_USERNAME:-}" && -n "${JENKINS_USER:-}" ]] && export JENKINS_USERNAME="${JENKINS_USER}"
  [[ -z "${JENKINS_API_TOKEN:-}" && -n "${JENKINS_TOKEN:-}" ]] && export JENKINS_API_TOKEN="${JENKINS_TOKEN}"
  if [[ -n "${JENKINS_BASE_URL:-}" ]]; then
    JENKINS_URL="${JENKINS_BASE_URL%/}"
  elif [[ -n "${JENKINS_PROBE_URL:-}" ]]; then
    JENKINS_URL="${JENKINS_PROBE_URL%/}"
  fi
}

jenkins_live_ok() {
  export JENKINS_URL JENKINS_USERNAME JENKINS_API_TOKEN JOB CPS_MARKER
  python3 << 'PY'
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import http.cookiejar

base = os.environ["JENKINS_URL"].rstrip("/")
user = os.environ["JENKINS_USERNAME"]
token = os.environ["JENKINS_API_TOKEN"]
job = os.environ["JOB"]
want = os.environ["CPS_MARKER"]
auth = base64.b64encode(f"{user}:{token}".encode()).decode()
cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

def call(path: str, method: str = "GET", data: bytes | None = None, extra: dict | None = None) -> tuple[int, str]:
    headers = {"Authorization": f"Basic {auth}"}
    if data is not None:
        headers["Content-Type"] = "application/xml; charset=UTF-8"
    if extra:
        headers.update(extra)
    req = urllib.request.Request(f"{base}{path}", data=data, method=method, headers=headers)
    try:
        with opener.open(req, timeout=120) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")

def wait_api(max_sec: int = 300) -> bool:
    deadline = time.time() + max_sec
    while time.time() < deadline:
        if call("/api/json")[0] == 200:
            return True
        time.sleep(5)
    return False

def live_cfg() -> tuple[int, str]:
    return call(f"/job/{urllib.parse.quote(job)}/config.xml")

def marker_ok(body: str) -> bool:
    m = re.search(r"paas-deploy-stages-load-[0-9a-z-]+", body)
    return bool(m and m.group(0) == want and "load paasLoadH1" in body and "runPaasDeploy()" in body)

if not wait_api():
    print("FAIL: Jenkins API not ready", file=sys.stderr)
    sys.exit(1)

code, body = live_cfg()
if code == 200 and marker_ok(body):
    print(f"OK: Jenkins LIVE job marker={want}")
    print("OK:live-multi-load")
    print("OK:live-run-call")
    sys.exit(0)

cfg_path = os.environ.get("TMP_CFG", "/tmp/paas-deploy-config.xml")
xml = open(cfg_path, "rb").read()
call(f"/job/{urllib.parse.quote(job)}/api/json")
extra: dict[str, str] = {}
ccode, cbody = call("/crumbIssuer/api/json")
if ccode == 200:
    crumb = json.loads(cbody)
    extra = {crumb["crumbRequestField"]: crumb["crumb"]}
pcode, pbody = call(f"/job/{urllib.parse.quote(job)}/config.xml", "POST", xml, extra)
if pcode not in (200, 201):
    print(f"WARN: POST config.xml HTTP {pcode}", file=sys.stderr)
    if pbody.strip():
        print(pbody[:400], file=sys.stderr)

deadline = time.time() + 120
while time.time() < deadline:
    code, body = live_cfg()
    if code == 200 and marker_ok(body):
        print(f"OK: Jenkins accepted config.xml (HTTP {pcode})" if pcode in (200, 201) else f"OK: Jenkins LIVE job marker={want}")
        print("OK:live-multi-load")
        print("OK:live-run-call")
        sys.exit(0)
    time.sleep(5)

sys.exit(2)
PY
}

load_jenkins_creds
[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "ERROR: set JENKINS_USERNAME and JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
}

echo "==> reload-jenkins-paas-deploy-job (${JENKINS_URL}/job/${JOB}/)"

kubectl exec -n "${JENKINS_NS}" deploy/jenkins -c jenkins --request-timeout=120s -- \
  cat "${JOB_CFG}" > "${TMP_CFG}"

export TMP_CFG
if jenkins_live_ok; then
  exit 0
fi

echo "WARN: live job still wrong — restarting Jenkins (reload config from PVC disk)"
kubectl rollout restart deploy/jenkins -n "${JENKINS_NS}"
kubectl rollout status deploy/jenkins -n "${JENKINS_NS}" --timeout=300s

export TMP_CFG=""
if jenkins_live_ok; then
  exit 0
fi

echo "FAIL: Jenkins LIVE job never showed ${CPS_MARKER} after POST + restart" >&2
exit 1
