#!/usr/bin/env bash
# Jenkins executor + queue snapshot. Use curl -g: tree=... contains [ ] which bash treats as globs.
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
fi
BASE="${JENKINS_PROBE_URL:-${BASE}}"

[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "ERROR: JENKINS_USERNAME / JENKINS_API_TOKEN in ${ENV_FILE}" >&2
  exit 1
}

AUTH=(-g -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}")

echo "==> Jenkins API ${BASE}"
curl "${AUTH[@]}" "${BASE}/api/json?tree=mode" | python3 -m json.tool 2>/dev/null || curl "${AUTH[@]}" "${BASE}/api/json"

echo ""
echo "==> Computers (executors)"
curl "${AUTH[@]}" "${BASE}/computer/api/json?depth=1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
for c in d.get('computer',[]):
    name=c.get('displayName','?')
    ne=c.get('numExecutors','?')
    idle=c.get('idleExecutors','?')
    busy=c.get('busyExecutors','?')
    off=c.get('offline','?')
    print(f'  {name}: num={ne} idle={idle} busy={busy} offline={off}')
"

echo ""
echo "==> ${JOB} — recent builds"
curl "${AUTH[@]}" \
  "${BASE}/job/${JOB}/api/json?tree=builds[number,building,result]" \
  | python3 -c "
import json,sys
d=json.load(sys.stdin)
for b in d.get('builds', [])[:12]:
    print(f\"  #{b.get('number')}: building={b.get('building')} result={b.get('result')}\")
"

echo ""
echo "==> Queue"
curl "${AUTH[@]}" \
  "${BASE}/queue/api/json?tree=items[why,task[name]]" \
  | python3 -m json.tool

echo ""
echo "==> lastBuild console (tail)"
curl "${AUTH[@]}" "${BASE}/job/${JOB}/lastBuild/consoleText" 2>/dev/null | tail -12 || echo "(no lastBuild yet)"
