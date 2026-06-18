#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE="${JENKINS_STAGES_REMOTE_PATH:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
DT_MARKER="${DT_STAGES_MARKER:-dt-api-server-svc-20260617}"
FAIL=0

echo "==> Verify Jenkins stages bundle on cluster (${DT_MARKER})"
if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl required" >&2
  exit 1
fi

FOUND=0
while read -r ns pod; do
  [[ -n "${ns}" && -n "${pod}" ]] || continue
  FOUND=1
  echo "-- ${ns}/${pod}"
  if kubectl exec -n "${ns}" "${pod}" -- test -f "${REMOTE}" 2>/dev/null; then
    if kubectl exec -n "${ns}" "${pod}" -- grep -qF "${DT_MARKER}" "${REMOTE}" 2>/dev/null \
      && kubectl exec -n "${ns}" "${pod}" -- grep -qF 'stage("Step 12 —' "${REMOTE}" 2>/dev/null; then
      echo "OK: ${REMOTE} has ${DT_MARKER} + Step 12 (June 17 load layout)"
    else
      echo "FAIL: ${REMOTE} exists but missing ${DT_MARKER} (stale — run bash paas/scripts/lab.sh jenkins)"
      FAIL=1
    fi
    if kubectl exec -n "${ns}" "${pod}" -- grep -qF 'pick_dt_base' "${REMOTE}" 2>/dev/null; then
      echo "FAIL: ${REMOTE} still contains legacy pick_dt_base"
      FAIL=1
    fi
  else
    echo "FAIL: ${REMOTE} not found in pod"
    FAIL=1
  fi
done < <(
  for ns in cicd jenkins devsecops; do
    kubectl get ns "${ns}" >/dev/null 2>&1 || continue
    kubectl get pods -n "${ns}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -iE 'jenkins' | grep -v Terminating | while read -r pod; do
          printf '%s %s\n' "${ns}" "${pod}"
        done || true
  done
)

if [[ "${FOUND}" -eq 0 ]]; then
  echo "FAIL: no Running Jenkins pod found"
  exit 1
fi

if [[ "${FAIL}" -ne 0 ]]; then
  exit 1
fi
echo "OK: Jenkins stages file is current on cluster"
