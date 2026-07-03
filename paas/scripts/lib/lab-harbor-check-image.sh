#!/usr/bin/env bash
set -euo pipefail
PROJECT="${1:?usage: lab-harbor-check-image.sh <project-slug> <build-tag>}"
TAG="${2:?usage: lab-harbor-check-image.sh <project-slug> <build-tag>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
user="${HARBOR_USER:-admin}"
pass="${HARBOR_PASS:-Harbor12345}"
if [[ -f "${ENV_FILE}" ]]; then
  user="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  pass="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${user}" ]] && user="admin"
  [[ -z "${pass}" ]] && pass="Harbor12345"
fi
url="http://${NODE_IP}:${HARBOR_PORT}/v2/paas/${PROJECT}/manifests/${TAG}"
code="$(curl -s -o /dev/null -w '%{http_code}' -u "${user}:${pass}" \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' "${url}" 2>/dev/null || echo '000')"
if [[ "${code}" == "200" ]]; then
  echo "OK: Harbor has paas/${PROJECT}:${TAG}"
  exit 0
fi
echo "MISSING: paas/${PROJECT}:${TAG} (HTTP ${code})" >&2
echo "  Jenkins build #${TAG} did not push an image (pipeline failed before Step 6?)." >&2
echo "  List tags: curl -s -u ${user}:*** http://${NODE_IP}:${HARBOR_PORT}/v2/paas/${PROJECT}/tags/list" >&2
echo "  Catalog:   curl -s -u ${user}:*** http://${NODE_IP}:${HARBOR_PORT}/v2/_catalog" >&2
exit 1
