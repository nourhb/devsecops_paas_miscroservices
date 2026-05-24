#!/usr/bin/env bash
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
JOB_MANIFEST="${PAAS_DIR}/k8s-manifests/lab/prisma-db-push-job.yaml"
IMAGE="${IMAGE:-paas-db-push:local}"

die() { echo "ERROR: $*" >&2; exit 1; }

kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s

echo "=== Build ${IMAGE} ==="
cd "${PAAS_DIR}"
docker build -f frontend/Dockerfile.db -t "${IMAGE}" .

PG_IP=$(kubectl get endpoints postgres -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
[[ -n "${PG_IP}" ]] || die "No postgres endpoints — run deploy-paas-postgres-lab.sh first"

DB_URL="postgresql://postgres:root@${PG_IP}:5432/paas?options=-c%20lc_messages%3DC"
echo "=== prisma db push (docker → ${PG_IP}) ==="
if docker run --rm -e DATABASE_URL="${DB_URL}" "${IMAGE}"; then
  echo "Schema push OK (docker)"
else
  echo "WARN: docker push failed — trying k3s Job..."
  TMP="/tmp/paas-db-push-$$.tar"
  docker save "${IMAGE}" -o "${TMP}"
  sudo k3s ctr images import "${TMP}" || true
  rm -f "${TMP}"
  kubectl delete job prisma-db-push -n "${PAAS_NS}" --ignore-not-found
  kubectl apply -f "${JOB_MANIFEST}" --validate=false
  kubectl wait --for=condition=complete job/prisma-db-push -n "${PAAS_NS}" --timeout=600s
  kubectl logs -n "${PAAS_NS}" job/prisma-db-push
fi

echo "=== Tables ==="
kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -c '\dt' | head -20

echo "OK: register/login at http://192.168.56.129:30100"
