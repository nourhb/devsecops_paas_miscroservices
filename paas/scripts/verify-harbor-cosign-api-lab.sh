#!/usr/bin/env bash
# Check Harbor API for cosign signature accessories (same fallback as Security UI).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
IMAGE="${1:?usage: verify-harbor-cosign-api-lab.sh IMAGE_REF}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u

REGISTRY="${HARBOR_REGISTRY:-}"
BASE="${HARBOR_BASE_URL%/}"
USER="${HARBOR_USERNAME:-}"
PASS="${HARBOR_PASSWORD:-}"

[[ -n "${REGISTRY}" && -n "${BASE}" && -n "${USER}" && -n "${PASS}" ]] || {
  echo "ERROR: HARBOR_REGISTRY, HARBOR_BASE_URL, HARBOR_USERNAME, HARBOR_PASSWORD required" >&2
  exit 1
}

TAG="${IMAGE##*:}"
REPO_PATH="${IMAGE#${REGISTRY}/}"
REPO_PATH="${REPO_PATH%:*}"
PROJECT="${REPO_PATH%%/*}"
REPO="${REPO_PATH#*/}"

ART_URL="${BASE}/api/v2.0/projects/${PROJECT}/repositories/${REPO}/artifacts/${TAG}"
ACC_URL="${ART_URL}/accessories"

echo "==> Artifact ${ART_URL}"
curl -fsS -u "${USER}:${PASS}" "${ART_URL}" | python3 -c "
import json,sys
d=json.load(sys.stdin)
links=d.get('addition_links') or {}
print('digest:', d.get('digest'))
print('addition_links:', ', '.join(links.keys()) or '(none)')
if 'signatures' in links:
    print('OK: artifact has signatures addition_link')
    sys.exit(0)
"

echo "==> Accessories ${ACC_URL}"
FOUND="$(curl -fsS -u "${USER}:${PASS}" "${ACC_URL}" | python3 -c "
import json,sys
items=json.load(sys.stdin)
if not isinstance(items, list):
    print('0'); sys.exit(0)
n=0
for a in items:
    t=str(a.get('artifact_type') or a.get('type') or '').lower()
    if 'cosign' in t or 'signature' in t:
        n+=1
        print('accessory:', t)
print(n)
" | tail -1)"

if [[ "${FOUND}" != "0" ]]; then
  echo "OK: ${IMAGE} has ${FOUND} cosign/signature accessory(ies) in Harbor"
  exit 0
fi

echo "ERROR: no cosign accessories in Harbor API for ${IMAGE}" >&2
exit 1
