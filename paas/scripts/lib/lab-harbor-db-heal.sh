#!/usr/bin/env bash
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

harbor_api_bases() {
  printf '%s\n' \
    "http://${NODE_IP}:${HARBOR_NODEPORT}" \
    "http://harbor.${NODE_IP}.nip.io:${HARBOR_NODEPORT}"
}

harbor_api_projects_code() {
  local base="$1"
  curl -sS -o /dev/null -w '%{http_code}' -u "${HARBOR_USER}:${HARBOR_PASS}" \
    --connect-timeout 8 --max-time 20 \
    "${base}/api/v2.0/projects?page_size=1" 2>/dev/null || echo 000
}

harbor_api_projects_ok() {
  local base code
  for base in $(harbor_api_bases); do
    code="$(harbor_api_projects_code "${base}")"
    [[ "${code}" == "200" ]] && return 0
  done
  return 1
}

harbor_v2_code() {
  local base="$1"
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
    "${base}/v2/" 2>/dev/null || echo 000
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

uncordon_pv_node() {
  local node="$1"
  [[ -n "${node}" ]] || return 0
  echo "==> uncordon ${node} + clear scheduling taints"
  kubectl uncordon "${node}" 2>/dev/null || true
  kubectl taint nodes "${node}" node.kubernetes.io/disk-pressure:NoSchedule- 2>/dev/null || true
  kubectl taint nodes "${node}" node.kubernetes.io/unreachable:NoSchedule- 2>/dev/null || true
  kubectl taint nodes "${node}" node.kubernetes.io/not-ready:NoSchedule- 2>/dev/null || true
}

heal_worker_for_pv() {
  local bound="$1" ip
  case "${bound}" in
    worker1) ip="192.168.56.128" ;;
    worker2) ip="192.168.56.130" ;;
    *) return 0 ;;
  esac
  echo "==> Harbor DB PVC on ${bound} — heal node (k3s-agent + uncordon)"
  uncordon_pv_node "${bound}"
  if [[ -f "${SCRIPT_DIR}/lab-worker2-heal.sh" ]]; then
    LAB_WORKER_NODE="${bound}" LAB_WORKER_IP="${ip}" bash "${SCRIPT_DIR}/lab-worker2-heal.sh" \
      || warn "${bound} heal failed — ssh ${bound} && sudo systemctl restart k3s-agent"
  else
    warn "run: LAB_WORKER_NODE=${bound} bash paas/scripts/lib/lab-worker2-heal.sh"
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
  echo "==> pin harbor-database StatefulSet to node ${node} (+ control-plane tolerations)"
  kubectl patch statefulset harbor-database -n "${HARBOR_NS}" --type=strategic -p \
    "{\"spec\":{\"template\":{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"${node}\"},\"tolerations\":[{\"key\":\"node-role.kubernetes.io/control-plane\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"},{\"key\":\"node-role.kubernetes.io/master\",\"operator\":\"Exists\",\"effect\":\"NoSchedule\"}]}}}}" \
    2>/dev/null || warn "could not patch harbor-database scheduling"
}

recreate_db_pvc_on_node() {
  local pvc pod target="${1:-${HARBOR_DB_NODE}}"
  pvc="$(harbor_db_pvc_name)"
  pod="$(harbor_db_pod)"
  warn "LAB-ONLY: recreating Harbor database PVC on ${target} (Harbor projects/users reset; registry blobs may remain)"
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
  uncordon_pv_node "${target}"
  patch_db_node_selector "${target}"
  scale_harbor_db_replicas 1
}

recreate_db_pvc_on_master() {
  recreate_db_pvc_on_node "${HARBOR_DB_NODE}"
}

wait_harbor_db() {
  local n=0 pod phase pending_fix=0
  echo "==> wait Harbor PostgreSQL ready (max $((72 * 5))s)"
  while [[ "${n}" -lt 72 ]]; do
    pod="$(harbor_db_pod)"
    phase="$(harbor_db_phase "${pod}")"
    if [[ "${phase}" == "Pending" ]] && [[ "${pending_fix}" -eq 0 ]]; then
      fix_pending_db_scheduling || true
      pending_fix=1
      n=0
      continue
    fi
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

fix_pending_db_scheduling() {
  local pod bound wstatus
  pod="$(harbor_db_pod)"
  [[ "$(harbor_db_phase "${pod}")" == "Pending" ]] || return 1
  bound="$(harbor_db_pv_node)"
  diagnose_pending_db "${pod}"
  uncordon_pv_node "${bound}"
  heal_worker_for_pv "${bound}"
  if [[ -z "${bound}" ]]; then
    warn "Harbor DB PVC has no PV node affinity — recreating on ${HARBOR_DB_NODE}"
    recreate_db_pvc_on_master
    return 0
  fi
  wstatus="$(kubectl get node "${bound}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo False)"
  sched="$(kubectl get node "${bound}" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || echo false)"
  if [[ "${wstatus}" != "True" ]] || [[ "${sched}" == "true" ]]; then
    warn "PV node ${bound} not schedulable (Ready=${wstatus} unschedulable=${sched}) — recreating DB PVC on ${HARBOR_DB_NODE}"
    recreate_db_pvc_on_master
    return 0
  fi
  echo "==> Pending: PV on schedulable node ${bound} — patch nodeSelector + tolerations"
  patch_db_node_selector "${bound}"
  recycle_db_pod "${pod}"
  sleep 8
  pod="$(harbor_db_pod)"
  if [[ "$(harbor_db_phase "${pod}")" == "Pending" ]]; then
    warn "still Pending on ${bound} after patch — recreating DB PVC on ${HARBOR_DB_NODE}"
    recreate_db_pvc_on_master
  fi
  return 0
}

restart_db_workload() {
  if kubectl get statefulset harbor-database -n "${HARBOR_NS}" >/dev/null 2>&1; then
    local phase pod
    pod="$(harbor_db_pod)"
    phase="$(harbor_db_phase "${pod}")"
    if [[ "${phase}" == "Pending" ]]; then
      fix_pending_db_scheduling
      return 0
    fi
    echo "==> rollout restart statefulset/harbor-database -n ${HARBOR_NS} (timeout ${ROLLout_TIMEOUT}s)"
    kubectl rollout restart statefulset/harbor-database -n "${HARBOR_NS}" 2>/dev/null || true
    kubectl rollout status statefulset/harbor-database -n "${HARBOR_NS}" --timeout="${ROLLout_TIMEOUT}s" 2>/dev/null \
      || warn "rollout status timed out — continuing with pod wait"
    return 0
  fi
  warn "no statefulset/harbor-database in ${HARBOR_NS}"
}

dedupe_harbor_core() {
  local ready n
  ready="$(kubectl get pods -n "${HARBOR_NS}" -l app=harbor,component=core \
    --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')"
  n="$(kubectl get deployment harbor-core -n "${HARBOR_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
  if [[ "${ready}" -gt 1 ]] || [[ "${n}" -gt 1 ]]; then
    echo "==> dedupe harbor-core (scale 1, drop CrashLoop/Completed)"
    kubectl scale deployment/harbor-core -n "${HARBOR_NS}" --replicas=1 2>/dev/null || true
    kubectl delete pod -n "${HARBOR_NS}" -l app=harbor,component=core \
      --field-selector=status.phase!=Running --force --grace-period=0 2>/dev/null || true
  fi
}

restart_harbor_apps() {
  dedupe_harbor_core
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

try_harbor_api_recover() {
  local helper="${SCRIPT_DIR}/lab-harbor.sh"
  if [[ -f "${helper}" ]]; then
    echo "==> Harbor API still unhealthy — run deeper recover helper"
    bash "${helper}" recover || true
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

  local n=0 base code v2
  until harbor_api_projects_ok; do
    n=$((n + 1))
    if [[ "${n}" -eq 18 ]]; then
      try_harbor_api_recover
    fi
    if [[ "${n}" -gt 36 ]]; then
      for base in $(harbor_api_bases); do
        code="$(harbor_api_projects_code "${base}")"
        v2="$(harbor_v2_code "${base}")"
        echo "Harbor probe ${base} -> /projects=${code} /v2=${v2}" >&2
      done
      kubectl get pods -n "${HARBOR_NS}" -o wide 2>/dev/null || true
      kubectl logs -n "${HARBOR_NS}" deploy/harbor-core --tail=80 2>/dev/null || true
      kubectl logs -n "${HARBOR_NS}" deploy/harbor-nginx --tail=80 2>/dev/null || true
      fail "Harbor API still failing after DB heal"
    fi
    echo "  waiting Harbor API (${n}/36)…"
    sleep 5
  done

  ok "Harbor API healthy — run: bash paas/scripts/lib/fix-harbor-push-now.sh"
}

main "$@"
