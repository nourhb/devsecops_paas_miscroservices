#!/usr/bin/env bash
# Jenkins (in-cluster) → push crane layers via Harbor nginx Service (not raw registry:5000).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

echo "==> Wire cluster Harbor hosts + HARBOR_REGISTRY_PUSH (nginx, not registry:5000)"
bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}"

PUSH="$(grep '^HARBOR_REGISTRY_PUSH=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"' || true)"
if [[ -z "${PUSH}" ]]; then
  echo "FAIL: HARBOR_REGISTRY_PUSH not set — kubectl get svc -n harbor" >&2
  exit 1
fi

echo "OK: crane push host=${PUSH} (external pull tag stays HARBOR_REGISTRY NodePort)"

echo ""
echo "==> Wait for Harbor registry pod 2/2 Ready (1/2 → crane HTTP 000)"
HARBOR_NS="${HARBOR_NS:-harbor}"
for i in $(seq 1 36); do
  ready="$(kubectl get pods -n "${HARBOR_NS}" -l app=harbor,component=registry \
    -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || true)"
  if echo "${ready}" | grep -q false; then
    echo "waiting registry containers (${i}/36): ${ready:-unknown}"
    sleep 10
  else
    echo "OK: harbor-registry containers ready (${ready})"
    break
  fi
  if [[ "${i}" -eq 36 ]]; then
    echo "WARN: registry pod not fully ready — check: kubectl logs -n harbor deploy/harbor-registry --all-containers --tail=40"
  fi
done

echo ""
bash "${SCRIPT_DIR}/recover-harbor-registry-lab.sh" || true

echo ""
echo "==> Probe from Jenkins pod"
if ! bash "${SCRIPT_DIR}/verify-harbor-push-from-jenkins-lab.sh"; then
  echo "FAIL: fix Jenkins → Harbor before triggering paas-deploy" >&2
  exit 1
fi

echo ""
echo "OK — next: bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "Console should show: Harbor crane push via in-cluster registry ${PUSH}"
