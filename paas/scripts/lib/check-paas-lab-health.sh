#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_PORT="${PAAS_PORT:-30100}"
FAIL=0
fail() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "OK: $*"; }
lab_ensure_kubeconfig || true
if ! lab_k8s_api_ready; then
  fail "k8s API"
  exit 1
fi
ok "k8s API"
if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
  PG_READY="$(kubectl get pods -n "${PAAS_NS}" -l app=postgres -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
  [[ "${PG_READY}" == "True" ]] && ok "postgres" || fail "postgres not ready"
else
  fail "no postgres deploy"
fi
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  DB_URL="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv DATABASE_URL 2>/dev/null || true)"
  if [[ "${DB_URL}" == *@postgres:* || "${DB_URL}" == *postgres.paas.svc.cluster.local* ]]; then
    ok "DATABASE_URL"
  else
    fail "bad DATABASE_URL"
  fi
else
  fail "no frontend deploy"
fi
if kubectl exec -n "${PAAS_NS}" deploy/frontend -- node -e "
const n=require('net');const s=n.connect(5432,'postgres');
s.on('connect',()=>process.exit(0));s.on('error',()=>process.exit(1));
setTimeout(()=>process.exit(1),8000);
" >/dev/null 2>&1; then
  ok "frontend TCP postgres:5432"
else
  fail "frontend cannot reach postgres:5432 (run: bash paas/scripts/lab.sh db-repair)"
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
echo "run: bash paas/scripts/lab.sh db-repair"
echo "auto-heal: bash paas/scripts/lab.sh harden   (installs 10-min watchdog cron)"
exit 1
