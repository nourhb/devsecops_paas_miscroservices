#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "OK: $*"; }
timeout 15 kubectl get --raw=/healthz >/dev/null 2>&1 || { fail "k8s API"; exit 1; }
ok "k8s API"
if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  PG_READY="$(kubectl get pods -n "${PAAS_NS}" -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
  [[ "${PG_READY}" == "True" ]] && ok "postgres" || fail "postgres not ready"
else
  fail "no postgres deploy"
fi
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  DB_URL="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv DATABASE_URL 2>/dev/null || true)"
  [[ "${DB_URL}" == *postgres.paas.svc.cluster.local* ]] && ok "DATABASE_URL" || fail "bad DATABASE_URL"
else
  fail "no frontend deploy"
fi
if kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT 1 FROM information_schema.tables WHERE table_name='User'" 2>/dev/null | grep -q 1; then
  ok "User table"
else
  fail "no User table"
fi
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "http://${NODE_IP}:${PAAS_PORT}/login" 2>/dev/null || echo 000)"
[[ "${HTTP}" == "200" || "${HTTP}" == "307" || "${HTTP}" == "308" ]] && ok "UI ${HTTP}" || fail "UI ${HTTP}"
API_HEALTH="$(curl -sS --connect-timeout 15 "http://${NODE_IP}:${PAAS_PORT}/api/health" 2>/dev/null || echo '{}')"
if echo "${API_HEALTH}" | grep -q '"connected":true'; then
  ok "Prisma from frontend pod"
else
  DB_ERR="$(echo "${API_HEALTH}" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p' | head -1)"
  fail "Prisma from frontend pod${DB_ERR:+ ($DB_ERR)}"
fi
if [[ "${FAIL}" -eq 0 ]]; then
  echo "http://${NODE_IP}:${PAAS_PORT}/login"
  exit 0
fi
echo "run: bash paas/scripts/lab.sh start"
exit 1
