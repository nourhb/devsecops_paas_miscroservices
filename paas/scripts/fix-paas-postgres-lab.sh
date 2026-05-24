#!/usr/bin/env bash
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
DB_NS="${DB_NS:-databases}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../k8s-manifests/lab/postgres-external-service.yaml"

echo "=== Postgres in ${PAAS_NS} ==="
kubectl get svc,pods -n "${PAAS_NS}" 2>/dev/null | grep -i postgres || echo "(no postgres pod/svc in ${PAAS_NS})"

echo "=== Postgres in ${DB_NS} ==="
kubectl get svc,pods -n "${DB_NS}" 2>/dev/null | grep -i postgres || true

if kubectl get svc postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "Service postgres already exists in ${PAAS_NS}"
else
  echo "=== Create ExternalName postgres → postgres-service.${DB_NS} ==="
  kubectl apply -f "${MANIFEST}"
fi

echo "=== Test DNS from frontend pod ==="
if kubectl get deploy frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  kubectl exec -n "${PAAS_NS}" deploy/frontend -- sh -c \
    'wget -qO- --timeout=3 postgres.paas.svc.cluster.local:5432 2>&1 | head -1 || nc -zvw2 postgres.paas.svc.cluster.local 5432 2>&1 || true' \
    2>/dev/null || echo "WARN: exec test failed — check frontend pod is Running"
fi

echo "=== Restart PaaS frontend ==="
kubectl rollout restart deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s 2>/dev/null || true

echo "OK: try login at http://192.168.56.129:30100/login"
echo "If still failing, DB creds may differ — check:"
echo "  kubectl exec -n ${DB_NS} deploy/postgres -- psql -U postgres -c '\\l' 2>/dev/null || true"
