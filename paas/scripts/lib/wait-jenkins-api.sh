#!/usr/bin/env bash
# Source from lab scripts. Sets JENKINS_WAIT_URL and waits until /api/json returns 200.
wait_jenkins_api() {
  local url="${1:-${JENKINS_PROBE_URL:-${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}}}"
  url="${url%/}"
  local max="${2:-120}"
  local i
  for i in $(seq 1 "${max}"); do
    if curl -fsS --connect-timeout 3 "${url}/api/json" >/dev/null 2>&1; then
      echo "OK: Jenkins API ready at ${url} (${i}s)"
      export JENKINS_WAIT_URL="${url}"
      return 0
    fi
    if [[ $((i % 10)) -eq 0 ]]; then
      echo "  waiting for Jenkins API (${i}/${max})…"
    fi
    sleep 1
  done
  echo "ERROR: Jenkins not ready at ${url} after ${max}s" >&2
  kubectl get pods -n "${JENKINS_NS:-cicd}" -l app=jenkins 2>/dev/null || true
  return 1
}
