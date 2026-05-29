#!/usr/bin/env bash
# Mark stale PENDING/DEPLOYING rows FAILED so the UI stops showing BUILDING/DEPLOYING forever.
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
PG_DEPLOY="${PG_DEPLOY:-deploy/postgres}"
PG_USER="${PG_USER:-postgres}"
PG_DB="${PG_DB:-paas}"

echo "==> Stale deployments in Postgres"
kubectl exec -n "${PAAS_NS}" "${PG_DEPLOY}" -- \
  psql -U "${PG_USER}" -d "${PG_DB}" -c \
  "SELECT id, status, \"jenkinsBuildNumber\", \"createdAt\" FROM \"Deployment\" WHERE status IN ('PENDING','DEPLOYING') ORDER BY \"createdAt\" DESC LIMIT 10;"

kubectl exec -n "${PAAS_NS}" "${PG_DEPLOY}" -- \
  psql -U "${PG_USER}" -d "${PG_DB}" -c \
  "UPDATE \"Deployment\" SET status='FAILED', \"failureMessage\"='Lab reset: Jenkins executor stuck / build aborted' WHERE status IN ('PENDING','DEPLOYING');"

echo "OK. Hard-refresh the project page in the browser (Ctrl+Shift+R)."
