#!/usr/bin/env bash
# Tag + cosign image at harbor.<nip>.nip.io (Kyverno rejects IP:port image refs on older Jenkins builds).
set -euo pipefail
PROJECT_SLUG="${1:?usage: ensure-harbor-nipio-cosign-lab.sh <slug> <tag>}"
IMAGE_TAG="${2:?usage: ensure-harbor-nipio-cosign-lab.sh <slug> <tag>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
SRC="${NODE_IP}:${HARBOR_PORT}/paas/${PROJECT_SLUG}:${IMAGE_TAG}"
DST="${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_SLUG}:${IMAGE_TAG}"

command -v crane >/dev/null 2>&1 || { echo "WARN: crane not installed — skip nip.io retag" >&2; exit 0; }
command -v cosign >/dev/null 2>&1 || { echo "WARN: cosign not installed — skip nip.io resign" >&2; exit 0; }

HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
if [[ -f "${ENV_FILE}" ]]; then
  HARBOR_USER="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  HARBOR_PASS="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${HARBOR_USER}" ]] && HARBOR_USER="admin"
  [[ -z "${HARBOR_PASS}" ]] && HARBOR_PASS="Harbor12345"
fi

echo "==> Harbor nip.io tag ${DST}"
crane auth login "${HARBOR_HOST}:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null \
  || crane auth login "${NODE_IP}:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null || true
if ! crane digest "${DST}" >/dev/null 2>&1; then
  crane copy "${SRC}" "${DST}" || crane tag "${SRC}" "${DST}"
fi
echo "OK: image at ${DST}"

COSIGN_KEY="${COSIGN_PRIVATE_KEY:-}"
if [[ -z "${COSIGN_KEY}" && -f "${ENV_FILE}" ]]; then
  COSIGN_KEY="$(grep -E '^COSIGN_PRIVATE_KEY=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
fi
if [[ -z "${COSIGN_KEY}" ]]; then
  echo "WARN: COSIGN_PRIVATE_KEY not set — skip resign" >&2
  exit 0
fi
export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
if [[ -z "${COSIGN_PASSWORD}" && -f "${ENV_FILE}" ]]; then
  COSIGN_PASSWORD="$(grep -E '^COSIGN_PASSWORD=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  export COSIGN_PASSWORD
fi
echo "==> cosign sign ${DST}"
cosign sign --yes --key "env://COSIGN_PRIVATE_KEY" "${DST}"
echo "OK: cosign signature on ${DST}"
