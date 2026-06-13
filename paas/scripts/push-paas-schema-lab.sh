#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
FRONTEND_DIR="${PAAS_DIR}/frontend"
IMAGE="${IMAGE:-paas-db-push:local}"
DOCKERFILE_DB="${FRONTEND_DIR}/Dockerfile.db"
die() { echo "ERROR: $*" >&2; exit 1; }
kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s
PG_IP=$(kubectl get endpoints postgres -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
[[ -n "${PG_IP}" ]] || die "No postgres endpoints — run deploy-paas-postgres-lab.sh first"
DB_URL="postgresql://postgres:root@${PG_IP}:5432/paas?options=-c%20lc_messages%3DC"
push_via_node_image() {
  echo "=== prisma db push (node:20-alpine + mounted frontend) ==="
  [[ -f "${FRONTEND_DIR}/package.json" ]] || die "Missing ${FRONTEND_DIR}/package.json — git pull from repo root"
  [[ -d "${FRONTEND_DIR}/prisma" ]] || die "Missing ${FRONTEND_DIR}/prisma"
  docker run --rm \
    -v "${FRONTEND_DIR}:/app" \
    -w /app \
    -e DATABASE_URL="${DB_URL}" \
    node:20-alpine \
    sh -ec 'apk add --no-cache openssl libc6-compat && npm ci && npx prisma generate && npx prisma db push'
}
push_via_dockerfile() {
  echo "=== Build ${IMAGE} ==="
  cd "${PAAS_DIR}"
  docker build -f frontend/Dockerfile.db -t "${IMAGE}" .
  echo "=== prisma db push (docker → ${PG_IP}) ==="
  docker run --rm -e DATABASE_URL="${DB_URL}" "${IMAGE}"
}
schema_pushed=0
if [[ -f "${DOCKERFILE_DB}" ]] && [[ "$(wc -c < "${DOCKERFILE_DB}")" -gt 80 ]]; then
  if push_via_dockerfile; then
    schema_pushed=1
  fi
else
  echo "WARN: ${DOCKERFILE_DB} missing or empty — run: git checkout paas/frontend/Dockerfile.db"
fi
if [[ "${schema_pushed}" -eq 0 ]]; then
  push_via_node_image
fi
echo "=== Tables ==="
kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -c '\dt' | head -20
echo "OK: register/login at http://192.168.56.129:30100"
