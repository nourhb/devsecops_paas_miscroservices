#!/usr/bin/env bash
# Lab script to sonarqube recover on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
SONAR_RELEASE="${SONAR_HELM_RELEASE:-sonarqube}"
SONAR_LAB_NODE="${SONAR_LAB_NODE:-master}"
SONAR_LAB_IMAGE_TAG="${SONAR_LAB_IMAGE_TAG:-10.8.0-community}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"
SONAR_TOKEN="${SONAR_TOKEN:-}"
SONAR_ADMIN_USER="${SONAR_ADMIN_USER:-admin}"
SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_PASSWORD:-}"

read_env_key() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] || return 1
  grep -m1 "^${key}=" "${file}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'" || true
}

load_sonar_creds() {
  if [[ -z "${SONAR_TOKEN}" ]]; then
    SONAR_TOKEN="$(read_env_key SONAR_TOKEN "${ENV_FILE}" || true)"
    [[ -n "${SONAR_TOKEN}" ]] || SONAR_TOKEN="$(read_env_key SONAR_TOKEN "${REPO_ROOT}/paas/frontend/.env" || true)"
  fi
  if [[ -z "${SONAR_ADMIN_PASSWORD}" ]]; then
    SONAR_ADMIN_PASSWORD="$(read_env_key SONAR_ADMIN_PASSWORD "${ENV_FILE}" || true)"
  fi
  SONAR_ADMIN_PASSWORD="${SONAR_ADMIN_PASSWORD:-SonarQube123!}"
}

sonar_curl_user() {
  local user="$1" pass="$2" timeout="$3"
  shift 3
  curl -sS -m "${timeout}" -u "${user}:${pass}" "$@"
}

sonar_status_up() {
  curl -fsS -m 15 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'
}

sonar_rules_http_admin() {
  local http pass
  for pass in "${SONAR_ADMIN_PASSWORD}" SonarQube123! admin; do
    http="$(sonar_curl_user "${SONAR_ADMIN_USER}" "${pass}" 45 -o /dev/null -w '%{http_code}' \
      "${SONAR_URL}/api/rules/search?activation=true&ps=1" 2>/dev/null || echo 000)"
    if [[ "${http}" == "200" ]]; then
      SONAR_ADMIN_PASSWORD="${pass}"
      echo 200
      return
    fi
  done
  echo "${http:-000}"
}

sonar_rules_ok() {
  [[ "$(sonar_rules_http_admin)" == "200" ]]
}

token_valid() {
  [[ -n "${SONAR_TOKEN}" ]] || return 1
  curl -fsS -m 15 -u "${SONAR_TOKEN}:" "${SONAR_URL}/api/authentication/validate" 2>/dev/null \
    | grep -q '"valid":true'
}

cancel_ce_tasks() {
  echo "==> Cancel pending Sonar compute-engine tasks"
  sonar_curl_user "${SONAR_ADMIN_USER}" "${SONAR_ADMIN_PASSWORD}" 20 -X POST \
    "${SONAR_URL}/api/ce/cancel_all" >/dev/null 2>&1 || true
}

run_sysctl() {
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@" 2>/dev/null || return 1
  else
    "$@" 2>/dev/null || return 1
  fi
}

ensure_node_sysctl_for_sonar() {
  echo "==> Host sysctl for Sonar (vm.max_map_count=524288 — required when init-sysctl disabled)"
  local conf="/etc/sysctl.d/99-sonarqube-paas.conf"
  if [[ -w /etc/sysctl.d ]] || command -v sudo >/dev/null 2>&1; then
    run_sysctl tee "${conf}" >/dev/null <<'EOF' || true
vm.max_map_count=524288
fs.file-max=131072
EOF
    run_sysctl sysctl --system >/dev/null 2>&1 || run_sysctl sysctl -p "${conf}" >/dev/null 2>&1 || true
  fi
  run_sysctl sysctl -w vm.max_map_count=524288 >/dev/null 2>&1 || true
  run_sysctl sysctl -w fs.file-max=131072 >/dev/null 2>&1 || true
  local cur
  cur="$(sysctl -n vm.max_map_count 2>/dev/null || echo 0)"
  echo "[sonar] vm.max_map_count=${cur}"
  if [[ "${cur}" -lt 524288 ]] 2>/dev/null; then
    echo "WARN: vm.max_map_count still low — on k3s master run: sudo sysctl -w vm.max_map_count=524288"
  fi
}

sonar_main_pod() {
  kubectl get pods -n "${SONAR_NS}" --request-timeout=20s -o name 2>/dev/null \
    | grep -E 'sonarqube-sonarqube|/sonarqube-[0-9]' | head -1 | sed 's|^pod/||' || true
}

apply_sysctl_all_k3s_nodes() {
  ensure_node_sysctl_for_sonar
  local nodes=(master worker1 worker2)
  local n
  for n in "${nodes[@]}"; do
    [[ "${n}" == "$(hostname -s 2>/dev/null || hostname)" ]] && continue
    if ssh -o ConnectTimeout=6 -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${n}" 'echo ok' 2>/dev/null; then
      echo "==> sysctl vm.max_map_count on ${n}"
      ssh "${n}" 'sudo sysctl -w vm.max_map_count=524288; sudo sysctl -w fs.file-max=131072' 2>/dev/null \
        || echo "WARN: sysctl on ${n} failed (passwordless sudo?)"
    else
      echo "WARN: ssh ${n} unavailable — if Sonar schedules there, run: sudo sysctl -w vm.max_map_count=524288"
    fi
  done
}

sonar_pod_waiting_reason() {
  local pod="$1"
  kubectl get pod -n "${SONAR_NS}" "${pod}" --request-timeout=15s \
    -o jsonpath='{.status.containerStatuses[?(@.name=="sonarqube")].state.waiting.reason}' 2>/dev/null || true
}

sonar_pod_needs_helm_repair() {
  local pod="$1"
  [[ -n "${pod}" ]] || return 0
  local reason
  reason="$(sonar_pod_waiting_reason "${pod}")"
  if [[ "${reason}" == "CrashLoopBackOff" || "${reason}" == "Error" ]]; then
    return 0
  fi
  sonar_pod_init_stuck "${pod}"
}

sonar_pod_init_stuck() {
  local pod="$1"
  [[ -n "${pod}" ]] || return 1
  local ready total
  ready="$(kubectl get pod -n "${SONAR_NS}" "${pod}" --request-timeout=15s \
    -o jsonpath='{.status.initContainerStatuses[*].ready}' 2>/dev/null || true)"
  total="$(kubectl get pod -n "${SONAR_NS}" "${pod}" --request-timeout=15s \
    -o jsonpath='{.spec.initContainers}' 2>/dev/null | grep -c '"name"' || echo 0)"
  [[ "${total}" -gt 0 ]] || return 1
  echo "${ready}" | grep -q false && return 0
  kubectl get pod -n "${SONAR_NS}" "${pod}" --request-timeout=15s \
    -o jsonpath='{.status.phase}' 2>/dev/null | grep -qiE 'Pending|Unknown' && return 0
  return 1
}

diagnose_sonar_pod() {
  local pod="$1"
  [[ -n "${pod}" ]] || { echo "WARN: no Sonar pod found in ${SONAR_NS}"; return 1; }
  echo "==> diagnose pod/${pod}"
  kubectl get pod -n "${SONAR_NS}" "${pod}" -o wide --request-timeout=20s 2>/dev/null || true
  kubectl describe pod -n "${SONAR_NS}" "${pod}" --request-timeout=30s 2>/dev/null \
    | tail -40 || true
  local c
  for c in $(kubectl get pod -n "${SONAR_NS}" "${pod}" --request-timeout=15s \
    -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null); do
    echo "--- init container logs: ${c} ---"
    kubectl logs -n "${SONAR_NS}" "${pod}" -c "${c}" --tail=50 2>/dev/null \
      || echo "(no logs yet for ${c})"
  done
  echo "--- sonarqube container logs (current) ---"
  kubectl logs -n "${SONAR_NS}" "${pod}" -c sonarqube --tail=80 2>/dev/null \
    || echo "(no current sonarqube logs)"
  echo "--- sonarqube container logs (previous crash) ---"
  kubectl logs -n "${SONAR_NS}" "${pod}" -c sonarqube --previous --tail=80 2>/dev/null \
    || echo "(no previous sonarqube logs)"
  local oom
  oom="$(kubectl get pod -n "${SONAR_NS}" "${pod}" --request-timeout=15s \
    -o jsonpath='{.status.containerStatuses[?(@.name=="sonarqube")].lastState.terminated.reason}' 2>/dev/null || true)"
  if [[ "${oom}" == "OOMKilled" ]]; then
    echo "WARN: sonarqube container was OOMKilled — helm repair raises memory limit"
  fi
}

wait_postgres_sonar() {
  local i pg_pod phase
  for i in $(seq 1 36); do
    pg_pod="$(kubectl get pods -n "${SONAR_NS}" --request-timeout=15s -o name 2>/dev/null \
      | grep -i postgresql | head -1 | sed 's|^pod/||' || true)"
    if [[ -n "${pg_pod}" ]]; then
      phase="$(kubectl get pod -n "${SONAR_NS}" "${pg_pod}" --request-timeout=15s \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      if [[ "${phase}" == "Running" ]]; then
        echo "OK: Sonar postgres ${pg_pod} Running"
        return 0
      fi
      echo "  [${i}/36] postgres ${pg_pod} phase=${phase:-unknown}"
    else
      echo "  [${i}/36] no postgresql pod in ${SONAR_NS} yet"
    fi
    sleep 10
  done
  return 1
}

helm_repair_sonar_lab() {
  command -v helm >/dev/null 2>&1 || { echo "WARN: helm missing — cannot helm repair Sonar"; return 1; }
  echo "==> helm upgrade ${SONAR_RELEASE} (lab: pin ${SONAR_LAB_NODE}, image ${SONAR_LAB_IMAGE_TAG}, relaxed startup probe)"
  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
  helm repo update sonarqube 2>/dev/null || true
  kubectl get ns "${SONAR_NS}" >/dev/null 2>&1 || kubectl create ns "${SONAR_NS}"
  helm upgrade --install "${SONAR_RELEASE}" sonarqube/sonarqube -n "${SONAR_NS}" \
    --set service.type=NodePort \
    --set "service.nodePort=${SONAR_PORT}" \
    --set postgresql.enabled=true \
    --set postgresql.primary.persistence.enabled=false \
    --set "postgresql.primary.nodeSelector.kubernetes\.io/hostname=${SONAR_LAB_NODE}" \
    --set community.enabled=true \
    --set "image.tag=${SONAR_LAB_IMAGE_TAG}" \
    --set monitoringPasscode=paas-lab-monitor \
    --set initSysctl.enabled=false \
    --set initFs.enabled=false \
    --set "nodeSelector.kubernetes\.io/hostname=${SONAR_LAB_NODE}" \
    --set-json 'tolerations=[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]' \
    --set startupProbe.initialDelaySeconds=120 \
    --set startupProbe.periodSeconds=15 \
    --set startupProbe.failureThreshold=60 \
    --set startupProbe.timeoutSeconds=5 \
    --set sonarProperties."sonar\\.web\\.javaOpts"="-Xmx1024m -Xms512m" \
    --set sonarProperties."sonar\\.ce\\.javaOpts"="-Xmx1024m -Xms512m" \
    --set resources.requests.memory=1Gi \
    --set resources.requests.cpu=250m \
    --set resources.limits.memory=3Gi \
    --set resources.limits.cpu=2 \
    --timeout 25m
}

restart_sonar_workload() {
  local dep sts
  cancel_ce_tasks
  dep="$(kubectl get deploy -n "${SONAR_NS}" --request-timeout=20s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${dep}" ]]; then
    echo "==> rollout restart deploy/${dep} -n ${SONAR_NS}"
    kubectl rollout restart "deploy/${dep}" -n "${SONAR_NS}" --request-timeout=60s
    kubectl rollout status "deploy/${dep}" -n "${SONAR_NS}" --timeout=180s --request-timeout=60s || true
  fi
  sts="$(kubectl get sts -n "${SONAR_NS}" --request-timeout=20s -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${sts}" ]]; then
    echo "==> rollout restart statefulset/${sts} -n ${SONAR_NS}"
    kubectl rollout restart "statefulset/${sts}" -n "${SONAR_NS}" --request-timeout=60s
    kubectl rollout status "statefulset/${sts}" -n "${SONAR_NS}" --timeout=180s --request-timeout=60s || true
  fi
}

wait_sonar_ready() {
  local i rules_http
  for i in $(seq 1 48); do
    if sonar_status_up && sonar_rules_ok; then
      echo "OK: SonarQube ready at ${SONAR_URL} (status UP + rules API 200, ${i} probe(s))"
      return 0
    fi
    rules_http="$(sonar_rules_http_admin)"
    if sonar_status_up; then
      echo "  [${i}/48] status UP but rules API HTTP ${rules_http} — waiting…"
    else
      echo "  [${i}/48] Sonar not UP yet…"
    fi
    sleep 10
  done
  return 1
}

repair_sonar_pod() {
  local pod="$1" reason="${2:-unhealthy}"
  apply_sysctl_all_k3s_nodes
  echo "WARN: Sonar pod ${reason} — helm repair (pin ${SONAR_LAB_NODE}) + recreate pod"
  diagnose_sonar_pod "${pod}" || true
  helm_repair_sonar_lab || true
  wait_postgres_sonar || echo "WARN: postgres not Running — check: kubectl get pods -n ${SONAR_NS}"
  kubectl delete pod -n "${SONAR_NS}" "${pod}" --ignore-not-found --wait=false --request-timeout=30s 2>/dev/null || true
  sleep 20
}

main() {
  load_sonar_creds
  echo "=============================================="
  echo " lab-sonarqube-recover — ${SONAR_URL}"
  echo "=============================================="
  kubectl get pods -n "${SONAR_NS}" -o wide --request-timeout=20s 2>/dev/null || true

  if sonar_status_up && sonar_rules_ok; then
    echo "OK: SonarQube healthy (rules API 200)"
    if ! token_valid; then
      echo "WARN: SONAR_TOKEN in env is invalid"
    fi
    exit 0
  fi

  apply_sysctl_all_k3s_nodes

  local pod reason
  pod="$(sonar_main_pod)"
  reason="$(sonar_pod_waiting_reason "${pod}")"

  if [[ -z "${pod}" ]] || ! kubectl get ns "${SONAR_NS}" >/dev/null 2>&1; then
    echo "WARN: Sonar namespace/pod missing — installing via helm"
    helm_repair_sonar_lab || true
    wait_postgres_sonar || true
  elif sonar_pod_needs_helm_repair "${pod}"; then
    repair_sonar_pod "${pod}" "${reason:-init-stuck}"
  elif sonar_status_up; then
    echo "WARN: Sonar UP but rules API HTTP $(sonar_rules_http_admin) — helm repair (rules loading)"
    repair_sonar_pod "${pod}" "rules-api"
  else
    echo "WARN: SonarQube not UP — helm repair (skip rollout-only restart)"
    repair_sonar_pod "${pod}" "not-up"
  fi

  if wait_sonar_ready; then
    if ! token_valid; then
      echo "Next: bash paas/scripts/lab.sh sonar-bootstrap && bash paas/scripts/lab.sh env-quick"
    fi
    echo "Then run ONE Jenkins deploy at a time."
    exit 0
  fi

  echo "FAIL: SonarQube still unhealthy at ${SONAR_URL}" >&2
  pod="$(sonar_main_pod)"
  diagnose_sonar_pod "${pod}" || true
  kubectl get pods -n "${SONAR_NS}" -o wide --request-timeout=20s 2>/dev/null || true
  echo "  On worker nodes: sudo sysctl -w vm.max_map_count=524288" >&2
  echo "  Or pin stays on master: SONAR_LAB_NODE=master bash paas/scripts/lab.sh sonarqube" >&2
  exit 1
}

main "$@"
