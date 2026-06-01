#!/usr/bin/env bash
# Upsert one key in paas/frontend/docker-compose.env and sync to k8s (optional).
set -euo pipefail
KEY="${1:?usage: set-lab-env-key.sh KEY VALUE [sync]}"
VAL="${2:?}"
SYNC="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${SCRIPT_DIR}/../frontend/docker-compose.env}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
if grep -q "^${KEY}=" "${ENV_FILE}" 2>/dev/null; then
  sed -i "s|^${KEY}=.*|${KEY}=${VAL}|" "${ENV_FILE}"
else
  echo "${KEY}=${VAL}" >> "${ENV_FILE}"
fi
echo "OK: ${KEY}=${VAL} in ${ENV_FILE}"
if [[ "${SYNC}" == "sync" || "${SYNC}" == "1" ]]; then
  bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
fi
