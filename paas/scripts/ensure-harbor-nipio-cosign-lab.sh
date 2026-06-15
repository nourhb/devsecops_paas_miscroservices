#!/usr/bin/env bash
# Tag + cosign image at harbor.<nip>.nip.io (works on VM host or via Jenkins/cosign pod).
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

HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
COSIGN_KEY="${COSIGN_PRIVATE_KEY:-}"
COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
if [[ -f "${ENV_FILE}" ]]; then
  HARBOR_USER="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  HARBOR_PASS="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${HARBOR_USER}" ]] && HARBOR_USER="admin"
  [[ -z "${HARBOR_PASS}" ]] && HARBOR_PASS="Harbor12345"
  [[ -z "${COSIGN_KEY}" ]] && COSIGN_KEY="$(grep -E '^COSIGN_PRIVATE_KEY=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${COSIGN_PASSWORD}" ]] && COSIGN_PASSWORD="$(grep -E '^COSIGN_PASSWORD=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
fi

run_crane_cosign_local() {
  command -v crane >/dev/null 2>&1 && command -v cosign >/dev/null 2>&1
}

run_via_jenkins() {
  local ns pod
  ns="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.metadata.labels}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | grep -v Terminating | head -1 | cut -f1 || true)"
  pod="$(kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | grep -v Terminating | head -1 | cut -f2 || true)"
  [[ -n "${ns}" && -n "${pod}" ]] || return 1
  echo "==> crane/cosign via pod ${ns}/${pod}"
  kubectl exec -n "${ns}" "${pod}" -- bash -c "
    set -e
    command -v crane >/dev/null || exit 1
    crane auth login ${HARBOR_HOST}:${HARBOR_PORT} -u '${HARBOR_USER}' -p '${HARBOR_PASS}' || \\
      crane auth login ${NODE_IP}:${HARBOR_PORT} -u '${HARBOR_USER}' -p '${HARBOR_PASS}'
    if ! crane digest '${DST}' >/dev/null 2>&1; then
      crane copy '${SRC}' '${DST}' || crane tag '${SRC}' '${DST}'
    fi
    export COSIGN_PRIVATE_KEY='${COSIGN_KEY//\'/\'\\\'\'}'
    export COSIGN_PASSWORD='${COSIGN_PASSWORD//\'/\'\\\'\'}'
    export COSIGN_EXPERIMENTAL=1
    cosign sign --yes --key env://COSIGN_PRIVATE_KEY '${DST}'
  "
}

echo "==> Harbor nip.io image ${DST}"
if crane digest "${DST}" >/dev/null 2>&1; then
  echo "OK: image already tagged at nip.io"
elif run_crane_cosign_local; then
  crane auth login "${HARBOR_HOST}:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null \
    || crane auth login "${NODE_IP}:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null || true
  crane copy "${SRC}" "${DST}" || crane tag "${SRC}" "${DST}"
  echo "OK: tagged ${DST}"
elif run_via_jenkins; then
  echo "OK: tagged via Jenkins pod"
else
  echo "WARN: could not retag image — continuing (signature may exist on digest)" >&2
fi

if [[ -z "${COSIGN_KEY}" ]]; then
  echo "WARN: COSIGN_PRIVATE_KEY not set — skip resign" >&2
  exit 0
fi
export COSIGN_PRIVATE_KEY="${COSIGN_KEY}"
export COSIGN_PASSWORD="${COSIGN_PASSWORD}"
export COSIGN_EXPERIMENTAL=1

if run_crane_cosign_local; then
  cosign sign --yes --key env://COSIGN_PRIVATE_KEY "${DST}"
elif run_via_jenkins; then
  echo "OK: cosign signed via Jenkins"
else
  echo "WARN: cosign sign skipped (install crane/cosign or ensure Jenkins pod has them)" >&2
  exit 0
fi
echo "OK: cosign signature on ${DST}"
