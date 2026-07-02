#!/usr/bin/env bash
# Reset PaaS login password or seed admin — fixes "Invalid credentials" after DB recover.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
FRONTEND_DIR="${REPO_ROOT}/paas/frontend"
NODE_IP="${NODE_IP:-192.168.56.129}"

log() { echo "[auth-reset] $*"; }
die() { echo "[auth-reset] FAIL: $*" >&2; exit 1; }

bash "${SCRIPT_DIR}/lab-postgres-safe.sh" ensure

pg_ip="$(k3s kubectl get endpoints postgres -n "${PAAS_NS}" \
  -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null \
  || kubectl get endpoints postgres -n "${PAAS_NS}" \
  -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
[[ -n "${pg_ip}" ]] || die "no postgres endpoints — bash paas/scripts/lab.sh db-repair"

db_url="postgresql://postgres:root@${pg_ip}:5432/paas?options=-c%20lc_messages%3DC"

run_node_script() {
  local script="$1"
  shift
  [[ -f "${FRONTEND_DIR}/${script}" ]] || die "missing ${FRONTEND_DIR}/${script}"
  docker run --rm \
    -v "${FRONTEND_DIR}:/app" \
    -w /app \
    -e DATABASE_URL="${db_url}" \
    node:20-alpine \
    sh -ec 'apk add --no-cache openssl libc6-compat >/dev/null && npm ci && npx prisma generate && node '"${script}"' "$@"' \
    _ "$@"
}

cmd="${1:-reset}"
shift || true
case "${cmd}" in
  reset|reset-password)
    email="${1:-}"
    password="${2:-}"
    [[ -n "${email}" && -n "${password}" ]] || die "usage: auth-reset reset <email> <password>"
    log "reset password for ${email}"
    run_node_script "scripts/reset-user-password.cjs" "${email}" "${password}"
    ;;
  seed|seed-admin)
    email="${1:-${SEED_ADMIN_EMAIL:-admin@paas.local}}"
    password="${2:-${SEED_ADMIN_PASSWORD:-123456789}}"
    full_name="${3:-${SEED_ADMIN_FULL_NAME:-Platform Admin}}"
    log "seed admin ${email}"
    run_node_script "scripts/seed-admin-user.cjs" "${email}" "${password}" "${full_name}"
    ;;
  *)
    die "usage: auth-reset {reset|seed} ..."
    ;;
esac

log "OK — login at http://${NODE_IP}:30100/login"
