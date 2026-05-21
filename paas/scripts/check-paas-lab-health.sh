#!/usr/bin/env bash
# Quick lab health check — run before demo/login/build. Exits 1 if anything critical fails.
# Usage: bash paas/scripts/check-paas-lab-health.sh
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
EXPECTED_DB_HOST="postgres.paas.svc.cluster.local"
FAIL=0

fail() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "OK: $*"; }

echo "=== PaaS lab health check ==="

if ! timeout 15 kubectl get --raw=/healthz >/dev/null 2>&1; then
  fail "Kubernetes API not ready — run: bash paas/scripts/recover-k3s-api-lab.sh"
  exit 1
fi
ok "Kubernetes API"

echo ""
echo "=== Postgres (namespace ${PAAS_NS}) ==="
if ! kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  fail "deployment/postgres missing — run: bash paas/scripts/bootstrap-paas-lab.sh"
else
  PG_READY="$(kubectl get pods -n "${PAAS_NS}" -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
  if [[ "${PG_READY}" != "True" ]]; then
    fail "postgres pod not Ready — run: bash paas/scripts/deploy-paas-postgres-lab.sh"
    kubectl get pods -n "${PAAS_NS}" -l app=postgres 2>/dev/null || true
  else
    ok "postgres pod Ready"
    if kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas >/dev/null 2>&1; then
      ok "pg_isready"
    else
      fail "pg_isready failed"
    fi
  fi
fi

echo ""
echo "=== Frontend env (DATABASE_URL) ==="
if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  fail "deployment/frontend missing"
else
  DB_URL="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv DATABASE_URL 2>/dev/null || true)"
  if [[ -z "${DB_URL}" ]]; then
    fail "DATABASE_URL unset on frontend — run: bash paas/scripts/sync-paas-frontend-env-k8s.sh"
  elif [[ "${DB_URL}" != *"${EXPECTED_DB_HOST}"* ]]; then
    fail "DATABASE_URL must contain ${EXPECTED_DB_HOST} (got wrong host) — fix docker-compose.env and sync"
    echo "       Current: ${DB_URL:0:80}..."
  else
    ok "DATABASE_URL points at ${EXPECTED_DB_HOST}"
  fi
fi

echo ""
echo "=== DB reachability from frontend pod ==="
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1 && \
   kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  if kubectl exec -n "${PAAS_NS}" deploy/frontend -- sh -c \
    'command -v pg_isready >/dev/null 2>&1 && pg_isready -h postgres.paas.svc.cluster.local -p 5432 -U postgres -d paas' >/dev/null 2>&1; then
    ok "frontend → postgres TCP"
  elif kubectl exec -n "${PAAS_NS}" deploy/frontend -- sh -c \
    'wget -qO- --timeout=5 postgres.paas.svc.cluster.local:5432 2>&1 | head -1' >/dev/null 2>&1; then
    ok "frontend → postgres (port open)"
  else
    fail "frontend cannot reach postgres:5432 — run: bash paas/scripts/recover-paas-after-k3s-restart.sh"
  fi
fi

echo ""
echo "=== Schema (User table) ==="
if kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='User'" 2>/dev/null | grep -q 1; then
  ok "User table exists"
else
  fail "User table missing — run: bash paas/scripts/push-paas-schema-lab.sh"
fi

echo ""
echo "=== PaaS HTTP ==="
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:${PAAS_PORT}/login" 2>/dev/null || echo 000)"
if [[ "${HTTP}" == "200" || "${HTTP}" == "307" || "${HTTP}" == "308" ]]; then
  ok "PaaS login page HTTP ${HTTP}"
else
  fail "PaaS login HTTP ${HTTP} — check frontend pod"
fi

echo ""
if [[ "${FAIL}" -eq 0 ]]; then
  echo "All checks passed. Safe to login at http://${NODE_IP}:${PAAS_PORT}/login"
  exit 0
fi
echo ""
echo "Fix everything at once:"
echo "  bash paas/scripts/recover-paas-after-k3s-restart.sh"
echo "Or full bootstrap:"
echo "  bash paas/scripts/bootstrap-paas-lab.sh"
exit 1
