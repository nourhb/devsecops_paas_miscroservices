#!/usr/bin/env bash
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
IMAGE="${SEED_ADMIN_IMAGE:-paas-seed-admin:local}"

SEED_EMAIL="${1:-admin@paas.local}"
SEED_PASSWORD="${2:-123456789}"
SEED_NAME="${3:-Platform Admin}"

die() { echo "ERROR: $*" >&2; exit 1; }

if [[ ! -f "${PAAS_DIR}/frontend/scripts/seed-admin-user.cjs" ]]; then
  die "Missing seed script — run: cd ~/devsecops_paas_miscroservices && git pull origin main"
fi

kubectl wait --for=condition=ready pod -l app=postgres -n "${PAAS_NS}" --timeout=120s

PG_IP="$(kubectl get endpoints postgres -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
[[ -n "${PG_IP}" ]] || die "No postgres endpoints — run deploy-paas-postgres-lab.sh first"

DB_URL="postgresql://postgres:root@${PG_IP}:5432/paas?options=-c%20lc_messages%3DC"

echo "=== Build ${IMAGE} ==="
cd "${PAAS_DIR}"
docker build -f frontend/Dockerfile.db -t "${IMAGE}" .

echo "=== Seed admin (docker → ${PG_IP}) ==="
docker run --rm \
  -e "DATABASE_URL=${DB_URL}" \
  -e "SEED_ADMIN_EMAIL=${SEED_EMAIL}" \
  -e "SEED_ADMIN_PASSWORD=${SEED_PASSWORD}" \
  -e "SEED_ADMIN_FULL_NAME=${SEED_NAME}" \
  "${IMAGE}"

echo ""
echo "Login: http://192.168.56.129:30100/login"
echo "  email:    ${SEED_EMAIL}"
echo "  password: (as passed to this script)"
