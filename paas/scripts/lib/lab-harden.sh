#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " lab-harden — one-shot: prevent PaaS lab outages"
echo "=============================================="

echo "==> 1/7 Kyverno fail-open when admission is down"
bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard || true

echo "==> 2/7 Frontend safety (Recreate + master pin — no worker1 pod storms)"
if [[ -f "${SCRIPT_DIR}/lab-frontend-lab-safety.sh" ]]; then
  bash "${SCRIPT_DIR}/lab-frontend-lab-safety.sh" apply || true
else
  bash "${SCRIPT_DIR}/lab-frontend-schedule-heal.sh" || true
fi

echo "==> 3/7 Postgres manifest + connectivity"
bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true

echo "==> 4/7 Safe disk baseline"
bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true
bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" ensure || true

echo "==> 5/7 Install auto-heal cron (watchdog every 10m + guard every 6h)"
bash "${SCRIPT_DIR}/lab-guard-cron.sh" install

echo "==> 6/7 Resume frontend if paused after storm"
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  PAUSED="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.paused}' 2>/dev/null || echo false)"
  REPLICAS="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
  DISK="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
  if [[ "${PAUSED}" == "true" && -n "${DISK}" && "${DISK}" -lt 85 ]]; then
    kubectl rollout resume deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
    if [[ "${REPLICAS}" == "0" ]]; then
      kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1 2>/dev/null || true
    fi
    kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s 2>/dev/null || true
  fi
fi

echo "==> 7/7 Health check"
if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
  echo ""
  echo "=============================================="
  echo " OK — lab hardened"
  echo " PaaS: http://${NODE_IP}:30100/login"
  echo " Auto-heal: every 10m (watchdog) + every 6h (guard)"
  echo " Log: /var/log/paas-lab-watchdog.log"
  echo "=============================================="
  exit 0
fi

echo ""
echo "WARN: health check still failing — run: bash paas/scripts/lab.sh db-repair"
echo "      then: bash paas/scripts/lab.sh health"
exit 1
