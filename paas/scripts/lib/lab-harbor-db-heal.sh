#!/usr/bin/env bash
# Heal Harbor PostgreSQL (harbor-database) — required before project/RBAC API or push tokens work.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
HARBOR_NS="${HARBOR_NS:-harbor}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-}"
HARBOR_DB_NODE="${HARBOR_DB_NODE:-master}"
ROLLout_TIMEOUT="${HARBOR_DB_ROLLOUT_TIMEOUT:-180}"

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

harbor_db_pod() {
  kubectl get pods -n "${HARBOR_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'database|postgresql' | grep -v Terminating | head -1 || true
}

harbor_db_phase() {
  local pod="${1:-$(harbor_db_pod)}"
  [[ -n "${pod}" ]] || { echo "Missing"; return; }
  kubectl get pod "${pod}" -n "${HARBOR_NS}" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown"
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

harbor_db_pvc_name() {
  kubectl get pvc -n "${HARBOR_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i database | head -1 || true
}

harbor_db_pv_node() {
  local pvc pv
  pvc="$(harbor_db_pvc_name)"
  [[ -n "${pvc}" ]] || return 0
  pv="$(kubectl get pvc "${pvc}" -n "${HARBOR_NS}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  [[ -n "${pv}" ]] || return 0
  kubectl get pv "${pv}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0]}' 2>/dev/null || true
}

diagnose_pending_db() {
  local pod="${1:-$(harbor_db_pod)}"
  echo "==> diagnose ${pod} (namespace ${HARBOR_NS})"
  kubectl get pod "${pod}" -n "${HARBOR_NS}" -o wide 2>/dev/null || true
  echo "--- Events ---"
  kubectl describe pod "${pod}" -n "${HARBOR_NS}" 2>/dev/null | sed -n '/Events:/,$p' | head -25 || true
  echo "--- PVC / PV ---"
  kubectl get pvc -n "${HARBOR_NS}" 2>/dev/null || true
  local bound
  bound="$(harbor_db_pv_node)"
  [[ -n "${bound}" ]] && echo "Harbor DB PV bound node: ${bound}"
  kubectl get nodes -o wide 2>/dev/null || true
}

heal_worker_for_pv() {
  local bound="$1"
  if [[ "${bound}" == worker2 ]] || [[ "${bound}" == *worker2* ]]; then
    echo "==> Harbor DB PVC on worker2 — heal worker2 first"
    if [[ -f "${SCRIPT_DIR}/lab-worker2-heal.sh" ]]; then
      bash "${SCRIPT_DIR}/lab-worker2-heal.sh" || warn "worker2 heal failed — try manual: bash paas/scripts/lab.sh worker2"
    else
      warn "run: bash paas/scripts/lab.sh worker2"
    fi
  fi
}

recycle_db_pod() {
  local pod="${1:-$(harbor_db_pod)}"
  [[ -n "${pod}" ]] || return 0
  echo "==> delete pod ${pod} (force reschedule)"
  kubectl delete pod "${pod}" -n "${HARBOR_NS}" --force --grace-period=0 --wait=false 2>/dev/null || true
}

scale_harbor_db_replicas() {
  local n="$1"
  if kubectl get statefulset harbor-database -n "${HARBOR_NS}" >/dev/null 2>&1; then
    kubectl scale statefulset/harbor-database -n "${HARBOR_NS}" --replicas="${n}" 2>/dev/null || true
  fi
}

patch_db_node_selector() {
  local node="$1"
  echo "==> pin harbor-database StatefulSet to node ${node}"
  kubectl patch statefulset harbor-database -n "${HARBOR_NS}" --type=merge -p \
    "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${node}\"}}}}}" \
    2>/dev/null || warn "could not patch harbor-database nodeSelector"
}

recreate_db_pvc_on_master() {
  local pvc pod
  pvc="$(harbor_db_pvc_name)"
  pod="$(harbor_db_pod)"
  warn "LAB-ONLY: recreating Harbor database PVC on ${HARBOR_DB_NODE} (Harbor projects/users reset; registry blobs may remain)"
  for deploy in harbor-core harbor-jobservice harbor-portal harbor-registry; do
    kubectl scale "deployment/${deploy}" -n "${HARBOR_NS}" --replicas=0 2>/dev/null || true
  done
  scale_harbor_db_replicas 0
  sleep 5
  [[ -n "${pod}" ]] && kubectl delete pod "${pod}" -n "${HARBOR_NS}" --force --grace-period=0 --wait=false 2>/dev/null || true
  if [[ -n "${pvc}" ]]; then
    local pv
    pv="$(kubectl get pvc "${pvc}" -n "${HARBOR_NS}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
    kubectl delete pvc "${pvc}" -n "${HARBOR_NS}" --wait=false 2>/dev/null || true
    if [[ -n "${pv}" ]]; then
      kubectl delete pv "${pv}" --wait=false 2>/dev/null || true
    fi
  fi
  patch_db_node_selector "${HARBOR_DB_NODE}"
  scale_harbor_db_replicas 1
}

wait_harbor_db() {
  local n=0 pod phase
  echo "==> wait Harbor PostgreSQL ready (max $((72 * 5))s)"
  while [[ "${n}" -lt 72 ]]; do
    pod="$(harbor_db_pod)"
    phase="$(harbor_db_phase "${pod}")"
    if [[ "${phase}" == "Pending" ]] && [[ $((n % 6)) -eq 0 ]] && [[ "${n}" -gt 0 ]]; then
      diagnose_pending_db "${pod}"
    fi
    if [[ -n "${pod}" ]] && [[ "${phase}" == "Running" ]] && harbor_db_pg_ready "${pod}"; then
      ok "PostgreSQL ready pod=${pod}"
      return 0
    fi
    n=$((n + 1))
    echo "  waiting DB (${n}/72) phase=${phase:-none}…"
    sleep 5
  done
  return 1
}

restart_db_workload() {
  if kubectl get statefulset harbor-database -n "${HARBOR_NS}" >/dev/null 2>&1; then
    local phase bound pod
    pod="$(harbor_db_pod)"
    phase="$(harbor_db_phase "${pod}")"
    bound="$(harbor_db_pv_node)"
    if [[ "${phase}" == "Pending" ]]; then
      diagnose_pending_db "${pod}"
      heal_worker_for_pv "${bound}"
      recycle_db_pod "${pod}"
      if [[ "${bound}" != "${HARBOR_DB_NODE}" ]] && [[ "${bound}" != "" ]]; then
        local wstatus
        wstatus="$(kubectl get node "${bound}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
        if [[ "${wstatus}" != "True" ]]; then
          warn "PV node ${bound} not Ready — recreating DB PVC on ${HARBOR_DB_NODE}"
          recreate_db_pvc_on_master
          return 0
        fi
      fi
    fi
    echo "==> rollout restart statefulset/harbor-database -n ${HARBOR_NS} (timeout ${ROLLout_TIMEOUT}s)"
    kubectl rollout restart statefulset/harbor-database -n "${HARBOR_NS}" 2>/dev/null || true
    kubectl rollout status statefulset/harbor-database -n "${HARBOR_NS}" --timeout="${ROLLout_TIMEOUT}s" 2>/dev/null \
      || warn "rollout status timed out — continuing with pod wait"
    return 0
  fi
  warn "no statefulset/harbor-database in ${HARBOR_NS}"
}

restart_harbor_apps() {
  for deploy in harbor-core harbor-jobservice harbor-registry harbor-nginx harbor-portal; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      kubectl scale "deployment/${deploy}" -n "${HARBOR_NS}" --replicas=1 2>/dev/null || true
      echo "==> rollout restart deployment/${deploy} -n ${HARBOR_NS}"
      kubectl rollout restart "deployment/${deploy}" -n "${HARBOR_NS}" || true
    fi
  done
  if kubectl get deployment harbor-core -n "${HARBOR_NS}" >/dev/null 2>&1; then
    kubectl rollout status "deployment/harbor-core" -n "${HARBOR_NS}" --timeout=300s || true
  fi
  kubectl delete pod -n "${HARBOR_NS}" -l app=harbor,component=core --field-selector=status.phase=Failed --force --grace-period=0 2>/dev/null || true
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

  echo "WARN: Harbor API unhealthy — healing database (Pending = PVC/node issue, not slow restart)"
  restart_db_workload
  if ! wait_harbor_db; then
    warn "DB still not ready — trying PVC recreate on ${HARBOR_DB_NODE}"
    recreate_db_pvc_on_master
    wait_harbor_db || {
      diagnose_pending_db
      fail "harbor-database still not ready — paste: kubectl describe pod harbor-database-0 -n harbor"
    }
  fi

  restart_harbor_apps
  sleep 10

  local n=0
  until harbor_api_projects_ok; do
    n=$((n + 1))
    [[ "${n}" -le 36 ]] || fail "Harbor API still failing — kubectl logs -n ${HARBOR_NS} deploy/harbor-core --tail=50"
    echo "  waiting Harbor API (${n}/36)…"
    sleep 5
  done

  ok "Harbor API healthy — run: bash paas/scripts/lib/fix-harbor-push-now.sh"
}

main "$@"
