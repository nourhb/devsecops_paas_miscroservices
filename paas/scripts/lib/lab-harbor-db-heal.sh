#!/usr/bin/env bash
# Heal Harbor PostgreSQL (harbor-database) — required before project/RBAC API or push tokens work.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARBOR_NS="${HARBOR_NS:-harbor}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

read_harbor_pass() {
  if [[ -z "${HARBOR_PASS}" ]] && command -v kubectl >/dev/null 2>&1; then
    HARBOR_PASS="$(kubectl get secret -n "${HARBOR_NS}" harbor-core \
      -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  [[ -n "${HARBOR_PASS}" ]] || HARBOR_PASS="Harbor12345"
}

harbor_db_pods() {
  kubectl get pods -n "${HARBOR_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'database|postgresql' | grep -v Terminating || true
}

harbor_db_pg_ready() {
  local pod="$1"
  kubectl exec -n "${HARBOR_NS}" "${pod}" --request-timeout=15s -- \
    pg_isready -U postgres -h 127.0.0.1 -p 5432 >/dev/null 2>&1 \
    || kubectl exec -n "${HARBOR_NS}" "${pod}" --request-timeout=15s -- \
    pg_isready -U postgres >/dev/null 2>&1
}

harbor_api_projects_ok() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${HARBOR_USER}:${HARBOR_PASS}" \
    --connect-timeout 8 --max-time 20 \
    "http://${NODE_IP}:${HARBOR_NODEPORT}/api/v2.0/projects?page_size=1" 2>/dev/null || echo 000)"
  [[ "${code}" == "200" ]]
}

wait_harbor_db() {
  local n=0 pod
  echo "==> wait Harbor PostgreSQL ready (namespace ${HARBOR_NS})"
  while [[ "${n}" -lt 72 ]]; do
    while IFS= read -r pod; do
      [[ -z "${pod}" ]] && continue
      if harbor_db_pg_ready "${pod}"; then
        ok "PostgreSQL ready pod=${pod}"
        return 0
      fi
    done <<< "$(harbor_db_pods)"
    n=$((n + 1))
    echo "  waiting DB (${n}/72)…"
    sleep 5
  done
  return 1
}

restart_db_workload() {
  local restarted=0
  for ss in harbor-database harbor-postgresql postgresql; do
    if kubectl get statefulset "${ss}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      echo "==> rollout restart statefulset/${ss} -n ${HARBOR_NS}"
      kubectl rollout restart "statefulset/${ss}" -n "${HARBOR_NS}"
      kubectl rollout status "statefulset/${ss}" -n "${HARBOR_NS}" --timeout=600s || true
      restarted=1
      break
    fi
  done
  for deploy in harbor-database; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      echo "==> rollout restart deployment/${deploy} -n ${HARBOR_NS}"
      kubectl rollout restart "deployment/${deploy}" -n "${HARBOR_NS}"
      kubectl rollout status "deployment/${deploy}" -n "${HARBOR_NS}" --timeout=600s || true
      restarted=1
    fi
  done
  [[ "${restarted}" == "1" ]] || warn "no harbor-database StatefulSet/Deployment found — check: kubectl get pods -n ${HARBOR_NS}"
}

restart_harbor_apps() {
  for deploy in harbor-core harbor-jobservice harbor-registry harbor-nginx harbor-portal; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      echo "==> rollout restart deployment/${deploy} -n ${HARBOR_NS}"
      kubectl rollout restart "deployment/${deploy}" -n "${HARBOR_NS}" || true
    fi
  done
  if kubectl get deployment harbor-core -n "${HARBOR_NS}" >/dev/null 2>&1; then
    kubectl rollout status "deployment/harbor-core" -n "${HARBOR_NS}" --timeout=300s || true
  fi
}

main() {
  echo "=============================================="
  echo " Harbor DB heal (${HARBOR_NS})"
  echo "=============================================="
  command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
  kubectl get ns "${HARBOR_NS}" >/dev/null 2>&1 || fail "namespace ${HARBOR_NS} missing — install Harbor first"
  read_harbor_pass

  echo "==> Harbor pods (database/core/registry)"
  kubectl get pods -n "${HARBOR_NS}" -o wide 2>/dev/null | grep -iE 'NAME|database|postgres|core|registry|nginx' || \
    kubectl get pods -n "${HARBOR_NS}" -o wide 2>/dev/null || true

  if harbor_api_projects_ok; then
    ok "Harbor API /api/v2.0/projects already healthy"
    exit 0
  fi

  echo "WARN: Harbor API unhealthy — healing database first (connection refused = harbor-database down)"
  restart_db_workload
  wait_harbor_db || {
    echo "FAIL: harbor-database still not ready" >&2
    kubectl describe pods -n "${HARBOR_NS}" 2>/dev/null | tail -40 || true
    kubectl get events -n "${HARBOR_NS}" --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true
    exit 1
  }

  restart_harbor_apps
  sleep 10

  local n=0
  until harbor_api_projects_ok; do
    n=$((n + 1))
    [[ "${n}" -le 36 ]] || fail "Harbor API still failing after DB heal — check: kubectl logs -n ${HARBOR_NS} deploy/harbor-core --tail=50"
    echo "  waiting Harbor API (${n}/36)…"
    sleep 5
  done

  ok "Harbor API healthy — run: bash paas/scripts/lib/fix-harbor-push-now.sh"
}

main "$@"
