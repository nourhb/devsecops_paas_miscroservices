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

helm_install_dtrack() {
  if ! command -v helm >/dev/null 2>&1; then
    warn "helm not installed — cannot auto-install Dependency-Track"
    return 1
  fi
  helm repo add dependency-track https://dependencytrack.github.io/helm-charts 2>/dev/null || true
  helm repo update dependency-track 2>/dev/null || helm repo update
  kubectl create namespace "${DT_NS}" --dry-run=client -o yaml | kubectl apply -f -
  echo "==> helm upgrade --install ${RELEASE} (lab resources, NodePort)"
  helm upgrade --install "${RELEASE}" dependency-track/dependency-track -n "${DT_NS}" \
    --set apiServer.service.type=NodePort \
    --set frontend.service.type=NodePort \
    --set apiServer.resources.requests.cpu=200m \
    --set apiServer.resources.requests.memory=1Gi \
    --set apiServer.resources.limits.cpu=1 \
    --set apiServer.resources.limits.memory=2Gi \
    --set persistence.storageClass=local-path \
    --wait --timeout 12m
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

echo "=============================================="
echo " lab-dependency-track — install / heal + env sync"
echo "=============================================="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "ERROR: kubectl required" >&2
  exit 1
fi

if ! kubectl get ns "${DT_NS}" >/dev/null 2>&1; then
  warn "namespace ${DT_NS} missing — installing Dependency-Track"
  helm_install_dtrack || fail "Dependency-Track helm install failed"
fi

API_POD="$(kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
API_PHASE="$(kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"

if [[ -z "${API_POD}" ]]; then
  warn "no API server pod in ${DT_NS} — installing or upgrading Dependency-Track"
  if ! helm_install_dtrack; then
    fail "Dependency-Track install/upgrade failed"
  fi
  API_POD="$(kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  API_PHASE="$(kubectl get pods -n "${DT_NS}" -l app.kubernetes.io/component=api-server -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)"
fi

if [[ -z "${API_POD}" ]]; then
  fail "Dependency-Track API server still missing after helm install"
  kubectl get pods,svc -n "${DT_NS}" 2>/dev/null || true
elif [[ "${API_PHASE}" != "Running" ]]; then
  warn "API server pod ${API_POD} phase=${API_PHASE:-?}"
  kubectl describe pod -n "${DT_NS}" "${API_POD}" 2>/dev/null | sed -n '/Events/,$p' | tail -15 || true
  warn "retrying helm upgrade with reduced resources"
  helm_install_dtrack || fail "helm upgrade did not recover API server"
else
  ok "API server pod ${API_POD} Running"
fi

IN_CLUSTER="http://dtrack-dependency-track-api-server.${DT_NS}.svc.cluster.local:8080"
JENKINS_LINE="$(discover_jenkins_pod || true)"
if [[ -n "${JENKINS_LINE}" ]]; then
  JNS="${JENKINS_LINE%% *}"
  JENKINS_POD="${JENKINS_LINE#* }"
  if kubectl exec -n "${JNS}" "${JENKINS_POD}" -- curl -fsS -m 15 "${IN_CLUSTER}/api/version" >/dev/null 2>&1; then
    ok "Jenkins pod ${JNS}/${JENKINS_POD} reaches ${IN_CLUSTER}"
  else
    warn "Jenkins cannot reach ${IN_CLUSTER} yet"
    FAIL=1
  fi
else
  warn "Jenkins pod not found — skip in-cluster probe"
fi

NODE_PORT=""
while read -r svc; do
  [[ -n "${svc}" ]] || continue
  np="$(kubectl get svc -n "${DT_NS}" "${svc}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    NODE_PORT="${np}"
    break
  fi
done < <(kubectl get svc -n "${DT_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

if [[ -n "${NODE_PORT}" && -f "${ENV_FILE}" ]]; then
  WANT_URL="http://${NODE_IP}:${NODE_PORT}"
  if grep -qE '^DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}"; then
    CURRENT="$(grep -E '^DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}" | head -1 | cut -d= -f2-)"
    if [[ "${CURRENT}" != "${WANT_URL}" ]] || [[ "${CURRENT}" == *":32313" ]]; then
      sed -i "s|^DEPENDENCY_TRACK_BASE_URL=.*|DEPENDENCY_TRACK_BASE_URL=${WANT_URL}|" "${ENV_FILE}"
      sed -i "s|^NEXT_PUBLIC_DEPENDENCY_TRACK_URL=.*|NEXT_PUBLIC_DEPENDENCY_TRACK_URL=${WANT_URL}|" "${ENV_FILE}" 2>/dev/null || true
      ok "updated DEPENDENCY_TRACK_BASE_URL -> ${WANT_URL}"
    else
      ok "DEPENDENCY_TRACK_BASE_URL=${WANT_URL}"
    fi
  else
    echo "DEPENDENCY_TRACK_BASE_URL=${WANT_URL}" >> "${ENV_FILE}"
    ok "added DEPENDENCY_TRACK_BASE_URL=${WANT_URL}"
  fi
  if grep -qE '^JENKINS_DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}"; then
    sed -i "s|^JENKINS_DEPENDENCY_TRACK_BASE_URL=.*|JENKINS_DEPENDENCY_TRACK_BASE_URL=${IN_CLUSTER}|" "${ENV_FILE}"
  else
    echo "JENKINS_DEPENDENCY_TRACK_BASE_URL=${IN_CLUSTER}" >> "${ENV_FILE}"
  fi
  ok "JENKINS_DEPENDENCY_TRACK_BASE_URL=${IN_CLUSTER}"
else
  warn "could not discover Dependency-Track NodePort — check: kubectl get svc -n ${DT_NS}"
  FAIL=1
fi

echo "=============================================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo "lab-dependency-track: OK"
  echo "Next:"
  echo "  bash paas/scripts/lab.sh env      # sync env to frontend + Jenkins params"
  echo "  bash paas/scripts/lab.sh jenkins  # push stages + job params"
  echo "  Trigger NEW Jenkins build (not Replay)"
  exit 0
fi
echo "lab-dependency-track: issues remain — review WARN/FAIL above"
exit 1
