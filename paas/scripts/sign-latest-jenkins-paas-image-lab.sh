#!/usr/bin/env bash
# Sign the image from Jenkins paas-deploy lastBuild console (PAAS_ARTIFACT_IMAGE or PAAS_BUILD_COMPLETE).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
JOB="${JENKINS_JOB:-paas-deploy}"
BUILD="${1:-lastBuild}"
REGISTRY="${HARBOR_REGISTRY:-192.168.56.129:30002}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${KEYDIR}/cosign.key" ]] || die "Missing ${KEYDIR}/cosign.key — run bash paas/scripts/setup-security-lab.sh"
[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}"

JENKINS_USER="$(grep '^JENKINS_USERNAME=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
JENKINS_TOKEN="$(grep '^JENKINS_API_TOKEN=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
[[ -n "${JENKINS_USER}" && -n "${JENKINS_TOKEN}" ]] || die "JENKINS_USERNAME / JENKINS_API_TOKEN missing in ${ENV_FILE}"

CONSOLE="$(curl -fsS -u "${JENKINS_USER}:${JENKINS_TOKEN}" \
  "http://127.0.0.1:30090/job/${JOB}/${BUILD}/consoleText" 2>/dev/null || true)"
[[ -n "${CONSOLE}" ]] || die "Could not fetch Jenkins console for ${JOB}/${BUILD}"

IMAGE="$(python3 - "${CONSOLE}" <<'PY'
import re, sys
text = sys.argv[1]
for pat in (
    r"PAAS_BUILD_COMPLETE\s+result=SUCCESS\s+image=(\S+)",
    r"PAAS_ARTIFACT_IMAGE=(\S+)",
):
    hits = re.findall(pat, text)
    if hits:
        print(hits[-1].strip())
        break
PY
)"
[[ -n "${IMAGE}" ]] || die "No PAAS_ARTIFACT_IMAGE in ${JOB}/${BUILD} console — run a successful deploy first"

export COSIGN_PASSWORD=""
echo "==> Signing ${IMAGE}"
cosign sign --yes --allow-insecure-registry \
  --key "${KEYDIR}/cosign.key" \
  "${IMAGE}"

echo "==> Verify (host)"
cosign verify --key "${KEYDIR}/cosign.pub" --allow-insecure-registry "${IMAGE}"

if kubectl get deployment frontend -n paas >/dev/null 2>&1; then
  echo "==> Verify (frontend pod)"
  kubectl exec -n paas deploy/frontend -- cosign verify \
    --key /etc/cosign/cosign.pub --allow-insecure-registry \
    "${IMAGE}" \
    || die "Frontend pod cosign verify failed — run: bash paas/scripts/mount-cosign-pub-frontend-lab.sh"
fi

echo "OK: signed and verified ${IMAGE}"
