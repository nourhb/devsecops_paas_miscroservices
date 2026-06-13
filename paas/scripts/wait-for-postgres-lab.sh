#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"
TIMEOUT_SEC="${TIMEOUT_SEC:-600}"
DEADLINE=$((SECONDS + TIMEOUT_SEC))
echo "==> Waiting for Postgres (max ${TIMEOUT_SEC}s)…"
while (( SECONDS < DEADLINE )); do
  if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
    if kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1; then
      echo "OK: Postgres ready"
      exit 0
    fi
  fi
  echo "  …postgres not ready yet ($(date -u +%H:%M:%S) UTC)"
  sleep 5
done
echo "ERROR: Postgres not ready after ${TIMEOUT_SEC}s" >&2
kubectl get pods,svc -n "${PAAS_NS}" 2>/dev/null | grep -E 'postgres|NAME' || true
exit 1
