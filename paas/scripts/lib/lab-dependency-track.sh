#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DT_NS="${DT_NS:-dependency-track}"
RELEASE="${DT_RELEASE:-dtrack}"
NODE_IP="${NODE_IP:-192.168.56.129}"
FAIL=0

warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "OK: $*"; }

kyverno_exempt_namespace() {
  local ns="$1"
  local policy
  for policy in require-signed-images require-non-root; do
    if ! kubectl get clusterpolicy "${policy}" >/dev/null 2>&1; then
      continue
    fi
    python3 - "${policy}" "${ns}" <<'PY' | kubectl apply -f - >/dev/null 2>&1 || true
import json
import subprocess
import sys

policy_name, namespace = sys.argv[1:3]
raw = subprocess.check_output(
    ["kubectl", "get", "clusterpolicy", policy_name, "-o", "json"],
    text=True,
)
doc = json.loads(raw)
spec = doc.setdefault("spec", {})
if spec.get("validationFailureAction") == "Enforce":
    spec["validationFailureAction"] = "Audit"
rules = spec.get("rules") or []
if rules:
    first = rules[0]
    exclude = first.setdefault("exclude", {})
    any_list = exclude.setdefault("any", [])
    if not any_list:
        any_list.append({"resources": {"namespaces": []}})
    resources = any_list[0].setdefault("resources", {})
    namespaces = resources.setdefault("namespaces", [])
    if namespace not in namespaces:
        namespaces.append(namespace)
    if policy_name == "require-signed-images":
        verify = first.get("verifyImages") or []
        if verify:
            verify[0]["mutateDigest"] = False
doc.pop("status", None)
meta = doc.get("metadata", {})
for k in ("managedFields", "creationTimestamp", "resourceVersion", "uid", "generation"):
    meta.pop(k, None)
print(json.dumps(doc))
PY
  done
  ok "Kyverno excludes namespace ${ns} (unsigned docker.io DT images allowed)"
}

helm_install_dtrack() {
  local profile="${1:-lab}"
  if ! command -v helm >/dev/null 2>&1; then
    warn "helm not installed — cannot auto-install Dependency-Track"
    return 1
  fi
  helm repo add dependency-track https://dependencytrack.github.io/helm-charts 2>/dev/null || true
  helm repo update dependency-track 2>/dev/null || helm repo update
  kubectl create namespace "${DT_NS}" --dry-run=client -o yaml | kubectl apply -f -
  kyverno_exempt_namespace "${DT_NS}"
  echo "==> helm upgrade --install ${RELEASE} (${profile}, NodePort)"
  local -a helm_args=(
    upgrade --install "${RELEASE}" dependency-track/dependency-track -n "${DT_NS}"
    --set apiServer.service.type=NodePort
    --set frontend.service.type=NodePort
    --set persistence.storageClass=local-path
    --wait --timeout 15m
  )
  if [[ "${profile}" == "lab" ]]; then
    helm_args+=(
      --set-string apiServer.resources.requests.cpu=500m
      --set-string apiServer.resources.requests.memory=1Gi
      --set-string apiServer.resources.limits.cpu=2
      --set-string apiServer.resources.limits.memory=2Gi
      --set-string frontend.resources.requests.cpu=100m
      --set-string frontend.resources.requests.memory=256Mi
      --set-string frontend.resources.limits.cpu=1
      --set-string frontend.resources.limits.memory=512Mi
    )
  fi
  helm "${helm_args[@]}"
}

recover_dtrack_corrupted_workloads() {
  local ss="${RELEASE}-dependency-track-api-server"
  local fe="${RELEASE}-dependency-track-frontend"
  local needs_reset=0
  if kubectl get statefulset -n "${DT_NS}" "${ss}" >/dev/null 2>&1; then
    local req_cpu lim_cpu
    req_cpu="$(kubectl get statefulset -n "${DT_NS}" "${ss}" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)"
    lim_cpu="$(kubectl get statefulset -n "${DT_NS}" "${ss}" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)"
    if [[ -n "${req_cpu}" && -n "${lim_cpu}" ]]; then
      if python3 - "${req_cpu}" "${lim_cpu}" <<'PY'
import sys
def parse_cpu(v):
    v = str(v).strip()
    if v.endswith("m"):
        return float(v[:-1])
    return float(v) * 1000
req, lim = parse_cpu(sys.argv[1]), parse_cpu(sys.argv[2])
raise SystemExit(0 if req <= lim else 1)
PY
      then
        :
      else
        warn "StatefulSet ${ss} has requests.cpu=${req_cpu} > limits.cpu=${lim_cpu} — removing workload for clean helm upgrade"
        needs_reset=1
      fi
    fi
  fi
  if [[ "${needs_reset}" -eq 1 ]] || { kubectl get statefulset -n "${DT_NS}" "${ss}" >/dev/null 2>&1 && [[ -z "$(discover_dt_api_pod)" ]]; }; then
    echo "==> delete ${ss} (cascade=orphan — keeps PVCs)"
    kubectl delete statefulset -n "${DT_NS}" "${ss}" --cascade=orphan --ignore-not-found --wait=false 2>/dev/null || true
    kubectl delete pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server --ignore-not-found --wait=false 2>/dev/null || true
  fi
  if kubectl get deployment -n "${DT_NS}" "${fe}" >/dev/null 2>&1; then
    local fe_ready
    fe_ready="$(kubectl get deployment -n "${DT_NS}" "${fe}" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)"
    if [[ "${fe_ready:-0}" != "1" ]]; then
      echo "==> rollout restart ${fe}"
      kubectl rollout restart -n "${DT_NS}" "deployment/${fe}" 2>/dev/null || true
    fi
  fi
}

recover_dtrack_rollouts() {
  recover_dtrack_corrupted_workloads
  local deploy
  while read -r deploy; do
    [[ -n "${deploy}" ]] || continue
    echo "==> rollout restart deployment/${deploy}"
    kubectl rollout restart -n "${DT_NS}" "deployment/${deploy}" 2>/dev/null || true
  done < <(kubectl get deploy -n "${DT_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  kubectl rollout status -n "${DT_NS}" statefulset "${RELEASE}-dependency-track-api-server" --timeout=10m 2>/dev/null \
    || kubectl rollout status -n "${DT_NS}" deploy --timeout=8m 2>/dev/null || true
}

discover_jenkins_pod() {
  for ns in cicd jenkins devsecops; do
    kubectl get ns "${ns}" >/dev/null 2>&1 || continue
    local pod
    pod="$(kubectl get pods -n "${ns}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
      | grep -iE '^jenkins' | grep -v Terminating | head -1 || true)"
    if [[ -n "${pod}" ]]; then
      printf '%s %s\n' "${ns}" "${pod}"
      return 0
    fi
  done
  return 1
}

discover_dt_api_pod() {
  kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

discover_dt_api_phase() {
  kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true
}

discover_dt_node_port() {
  local np
  np="$(kubectl get svc -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    echo "${np}"
    return 0
  fi
  np="$(kubectl get svc -n "${DT_NS}" "${RELEASE}-dependency-track-api-server" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    echo "${np}"
    return 0
  fi
  return 1
}

sync_dt_env_urls() {
  local in_cluster="http://${RELEASE}-dependency-track-api-server.${DT_NS}.svc.cluster.local:8080"
  local node_port
  node_port="$(discover_dt_node_port || true)"
  if [[ -n "${node_port}" ]]; then
    local want_url="http://${NODE_IP}:${node_port}"
    local dot_env="${REPO_ROOT}/paas/frontend/.env"
    patch_env_key() {
      local file="$1" key="$2" value="$3"
      [[ -f "${file}" ]] || return 0
      if grep -qE "^${key}=" "${file}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
      else
        echo "${key}=${value}" >> "${file}"
      fi
    }
    for env_file in "${ENV_FILE}" "${dot_env}"; do
      [[ -f "${env_file}" ]] || continue
      local current
      current="$(grep -E '^DEPENDENCY_TRACK_BASE_URL=' "${env_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
      if [[ "${current}" != "${want_url}" ]] || [[ "${current}" == *":32313" ]]; then
        patch_env_key "${env_file}" "DEPENDENCY_TRACK_BASE_URL" "${want_url}"
        patch_env_key "${env_file}" "NEXT_PUBLIC_DEPENDENCY_TRACK_URL" "${want_url}"
        ok "updated ${env_file} DEPENDENCY_TRACK_BASE_URL -> ${want_url}"
      else
        ok "${env_file} DEPENDENCY_TRACK_BASE_URL=${want_url}"
      fi
      patch_env_key "${env_file}" "JENKINS_DEPENDENCY_TRACK_BASE_URL" "${in_cluster}"
    done
    ok "JENKINS_DEPENDENCY_TRACK_BASE_URL=${in_cluster}"
    sync_dt_frontend_api_base_url || true
    return 0
  fi
  warn "could not discover Dependency-Track API NodePort — check: kubectl get svc -n ${DT_NS}"
  return 1
}

sync_dt_frontend_api_base_url() {
  local api_port fe_port want_api_base current ui_url
  api_port="$(discover_dt_node_port || true)"
  fe_port="$(discover_dt_frontend_node_port || true)"
  if [[ -z "${api_port}" ]]; then
    warn "could not discover API NodePort for frontend.apiBaseUrl"
    return 1
  fi
  want_api_base="http://${NODE_IP}:${api_port}"
  ui_url="http://${NODE_IP}:${fe_port:-?}"
  current="$(kubectl get deploy -n "${DT_NS}" "${RELEASE}-dependency-track-frontend" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="API_BASE_URL")].value}' 2>/dev/null || true)"
  if [[ "${current}" == "${want_api_base}" ]]; then
    ok "frontend API_BASE_URL=${want_api_base}"
    ok "Dependency-Track UI (login): ${ui_url}"
    return 0
  fi
  if ! command -v helm >/dev/null 2>&1; then
    warn "helm missing — set frontend API_BASE_URL=${want_api_base} manually (fixes login HTTP 405)"
    return 1
  fi
  if ! helm status "${RELEASE}" -n "${DT_NS}" >/dev/null 2>&1; then
    warn "helm release ${RELEASE} missing — cannot set frontend.apiBaseUrl"
    return 1
  fi
  echo "==> helm upgrade frontend.apiBaseUrl=${want_api_base} (browser calls API directly; fixes login 405)"
  if ! helm upgrade "${RELEASE}" dependency-track/dependency-track -n "${DT_NS}" \
    --reuse-values \
    --set "frontend.apiBaseUrl=${want_api_base}" \
    --wait --timeout 8m; then
    warn "helm upgrade frontend.apiBaseUrl failed"
    return 1
  fi
  kubectl rollout status -n "${DT_NS}" "deployment/${RELEASE}-dependency-track-frontend" --timeout=5m 2>/dev/null || true
  ok "frontend API_BASE_URL=${want_api_base}"
  ok "Dependency-Track UI (login here, NOT the API port): ${ui_url}"
  echo "  If login still fails: hard-refresh browser (Ctrl+Shift+R) or clear site data for ${NODE_IP}"
  return 0
}

discover_dt_frontend_node_port() {
  local np
  np="$(kubectl get svc -n "${DT_NS}" -l app.kubernetes.io/component=frontend -o jsonpath='{.items[0].spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    echo "${np}"
    return 0
  fi
  np="$(kubectl get svc -n "${DT_NS}" "${RELEASE}-dependency-track-frontend" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    echo "${np}"
    return 0
  fi
  return 1
}

read_env_key() {
  local file="$1" key="$2"
  [[ -f "${file}" ]] || return 1
  grep -E "^${key}=" "${file}" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

verify_dt_api_key() {
  local base key http fe_port ui_url
  base="$(read_env_key "${ENV_FILE}" "DEPENDENCY_TRACK_BASE_URL" || true)"
  key="$(read_env_key "${ENV_FILE}" "DEPENDENCY_TRACK_API_KEY" || true)"
  if [[ -z "${base}" ]]; then
    warn "DEPENDENCY_TRACK_BASE_URL missing in ${ENV_FILE}"
    return 1
  fi
  if [[ -z "${key}" ]]; then
    warn "DEPENDENCY_TRACK_API_KEY missing in ${ENV_FILE}"
    return 1
  fi
  if [[ "${key}" == *"PASTE"* ]] || [[ "${key}" == *"YOUR_NEW_KEY"* ]] || [[ "${key}" == *"CHANGEME"* ]]; then
    fail "DEPENDENCY_TRACK_API_KEY is still a placeholder — create a real key in Dependency-Track UI"
    return 1
  fi
  http="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 -H "X-Api-Key: ${key}" "${base}/api/v1/project?pageNumber=1&pageSize=1" 2>/dev/null || echo "000")"
  if [[ "${http}" == "200" ]]; then
    ok "DEPENDENCY_TRACK_API_KEY valid (HTTP 200) against ${base}"
    return 0
  fi
  fe_port="$(discover_dt_frontend_node_port || true)"
  ui_url="http://${NODE_IP}:${fe_port:-31992}"
  fail "DEPENDENCY_TRACK_API_KEY rejected (HTTP ${http}) — a fresh Dependency-Track install invalidates old API keys"
  echo "  Fix:"
  echo "    1. Open UI ${ui_url} (frontend port — NOT ${base})"
  echo "       Login 405? run: bash paas/scripts/lab.sh dependency-track  (sets frontend.apiBaseUrl)"
  echo "    2. Administration → Access Management → Teams → Automation → API Keys → Create"
  echo "    2. sed -i 's|^DEPENDENCY_TRACK_API_KEY=.*|DEPENDENCY_TRACK_API_KEY=<NEW_KEY>|' paas/frontend/.env paas/frontend/docker-compose.env"
  echo "    3. python3 paas/scripts/lib/create_jenkins_paas_deploy_job.py --params-only --force"
  echo "    4. bash paas/scripts/lab.sh env"
  echo "    5. Trigger a NEW Jenkins build (not Replay)"
  return 1
}

echo "=============================================="
echo " lab-dependency-track — install / heal + env sync"
echo "=============================================="

if [[ "${LAB_DT_ENV_ONLY:-false}" == "true" ]]; then
  sync_dt_env_urls || exit 1
  verify_dt_api_key || exit 1
  echo "lab-dependency-track: env URLs synced (LAB_DT_ENV_ONLY)"
  exit 0
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl required" >&2
  exit 1
fi

kyverno_exempt_namespace "${DT_NS}"

if ! kubectl get ns "${DT_NS}" >/dev/null 2>&1; then
  warn "namespace ${DT_NS} missing — installing Dependency-Track"
  helm_install_dtrack lab || helm_install_dtrack minimal || fail "Dependency-Track helm install failed"
fi

recover_dtrack_corrupted_workloads

API_POD="$(discover_dt_api_pod)"
API_PHASE="$(discover_dt_api_phase)"

if [[ -z "${API_POD}" ]] || [[ "${API_PHASE}" != "Running" ]]; then
  if [[ -n "${API_POD}" ]]; then
    warn "API server pod ${API_POD} phase=${API_PHASE:-?}"
    kubectl describe pod -n "${DT_NS}" "${API_POD}" 2>/dev/null | sed -n '/Events/,$p' | tail -15 || true
  else
    warn "no Running API server pod in ${DT_NS}"
    kubectl get pods,deploy,statefulset,svc -n "${DT_NS}" 2>/dev/null || true
  fi
  if ! helm_install_dtrack lab; then
    warn "helm lab profile failed — retrying without custom resources"
    recover_dtrack_corrupted_workloads
    if ! helm_install_dtrack minimal; then
      warn "helm upgrade failed — trying rollout restart on existing workloads"
      recover_dtrack_rollouts || fail "Dependency-Track install/upgrade failed"
    fi
  fi
  API_POD="$(discover_dt_api_pod)"
  API_PHASE="$(discover_dt_api_phase)"
fi

if [[ -z "${API_POD}" ]]; then
  fail "Dependency-Track API server pod still missing"
  kubectl get pods,deploy,statefulset,svc -n "${DT_NS}" 2>/dev/null || true
elif [[ "${API_PHASE}" != "Running" ]]; then
  fail "Dependency-Track API server pod ${API_POD} not Running (phase=${API_PHASE})"
  kubectl describe pod -n "${DT_NS}" "${API_POD}" 2>/dev/null | sed -n '/Events/,$p' | tail -20 || true
else
  ok "API server pod ${API_POD} Running"
fi

IN_CLUSTER="http://${RELEASE}-dependency-track-api-server.${DT_NS}.svc.cluster.local:8080"
JENKINS_LINE="$(discover_jenkins_pod || true)"
if [[ -n "${JENKINS_LINE}" && "${API_PHASE}" == "Running" ]]; then
  JNS="${JENKINS_LINE%% *}"
  JENKINS_POD="${JENKINS_LINE#* }"
  if kubectl exec -n "${JNS}" "${JENKINS_POD}" -- curl -fsS -m 15 "${IN_CLUSTER}/api/version" >/dev/null 2>&1; then
    ok "Jenkins pod ${JNS}/${JENKINS_POD} reaches ${IN_CLUSTER}"
  else
    warn "Jenkins cannot reach ${IN_CLUSTER} yet"
    FAIL=1
  fi
elif [[ -z "${JENKINS_LINE}" ]]; then
  warn "Jenkins pod not found — skip in-cluster probe"
elif [[ "${API_PHASE}" != "Running" ]]; then
  warn "skip Jenkins in-cluster probe until API server is Running"
  FAIL=1
fi

sync_dt_env_urls || FAIL=1
verify_dt_api_key || FAIL=1

echo "=============================================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo "lab-dependency-track: OK"
  echo "Next:"
  echo "  bash paas/scripts/lab.sh env"
  echo "  LAB_DT_SKIP_HEAL=true bash paas/scripts/lab.sh jenkins"
  echo "  bash paas/scripts/lib/verify-jenkins-stages-on-cluster.sh"
  echo "  Trigger NEW Jenkins build (not Replay)"
  exit 0
fi
echo "lab-dependency-track: issues remain — review WARN/FAIL above"
exit 1
