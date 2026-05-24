#!/usr/bin/env bash
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
INGRESS_PORT="${APPS_PUBLIC_INGRESS_HTTP_PORT:-30659}"
PAAS_NS="${PAAS_NS:-paas}"
PROJECT_NAME="${PROJECT_NAME:-simple-app}"
CANONICAL_URL="http://${PROJECT_NAME}.${NODE_IP}.nip.io:${INGRESS_PORT}"

echo "=== [1] PaaS frontend env (nip.io link generation) ==="
bash "$(dirname "$0")/patch-paas-frontend-lab-urls.sh"

echo ""
echo "=== [2] Update stored URLs in Postgres (deployment history rows) ==="
PG_POD="$(kubectl get pods -n "${PAAS_NS}" -o name 2>/dev/null | grep -i postgres | head -1 || true)"
if [[ -z "${PG_POD}" ]]; then
  echo "WARN: no postgres pod in ${PAAS_NS} — UI still uses nip.io after frontend env patch + code refresh"
else
  kubectl exec -n "${PAAS_NS}" "${PG_POD}" -- psql -U postgres -d paas -v ON_ERROR_STOP=1 <<SQL
UPDATE "Project"
SET url = '${CANONICAL_URL}'
WHERE "projectName" = '${PROJECT_NAME}';

UPDATE "Deployment" d
SET url = '${CANONICAL_URL}'
FROM "Project" p
WHERE d."projectId" = p.id AND p."projectName" = '${PROJECT_NAME}';

UPDATE "Deployment"
SET url = regexp_replace(url, '\\.apps\\.local/?$', '.${NODE_IP}.nip.io:${INGRESS_PORT}')
WHERE url LIKE '%.apps.local%';
SQL
  echo "Postgres URLs updated for ${PROJECT_NAME} → ${CANONICAL_URL}"
fi

echo ""
echo "=== [3] GitOps ingress host (should match UI) ==="
GITOPS="${GITOPS:-${HOME}/gitops}"
VALUES="${GITOPS}/apps/simple-app/values.yaml"
if [[ -f "${VALUES}" ]]; then
  HOST="${PROJECT_NAME}.${NODE_IP}.nip.io"
  if grep -q "nip.io" "${VALUES}"; then
    echo "values.yaml already has nip.io host"
  else
    sed -i "s|host:.*|host: ${HOST}|" "${VALUES}" 2>/dev/null || true
    echo "Patched ${VALUES} — commit/push gitops if Argo should reconcile"
  fi
else
  echo "No ${VALUES} — clone ~/gitops or push chart from PaaS"
fi

echo ""
echo "=== [4] Verify (same URL as PaaS UI) ==="
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "${CANONICAL_URL}/" 2>/dev/null || true)"
HTTP="${HTTP:-000}"
echo "Open in browser: ${CANONICAL_URL}"
echo "HTTP ${HTTP}"
echo "PaaS UI: http://${NODE_IP}:30100 → project ${PROJECT_NAME} → link should match above"
