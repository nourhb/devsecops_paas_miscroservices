#!/usr/bin/env bash
# Deploy Postgres inside namespace paas (matches DATABASE_URL postgres.paas.svc.cluster.local).
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="${SCRIPT_DIR}/../k8s-manifests/lab/postgres-in-paas.yaml"
DB_URL='postgresql://postgres:root@postgres.paas.svc.cluster.local:5432/paas?options=-c%20lc_messages%3DC'

echo "=== Remove broken ExternalName / headless postgres Service (if any) ==="
kubectl delete svc postgres -n "${PAAS_NS}" --ignore-not-found

echo "=== Deploy Postgres in ${PAAS_NS} ==="
kubectl apply -f "${MANIFEST}"

kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=300s
kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s

echo "=== Point frontend at postgres.paas ==="
kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s

kubectl get pods,svc,endpoints -n "${PAAS_NS}" | grep -E 'postgres|frontend|NAME'
kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv DATABASE_URL
kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas

echo "OK: login at http://192.168.56.129:30100/login"
echo "If schema missing: kubectl exec -n ${PAAS_NS} deploy/frontend -- npx prisma db push"
