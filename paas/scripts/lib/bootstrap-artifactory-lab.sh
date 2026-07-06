#!/usr/bin/env bash
# Lab helper script for bootstrap artifactory lab
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
ARTI_NS="${ARTIFACTORY_NS:-artifactory}"
ARTI_PORT="${ARTIFACTORY_NODEPORT:-30802}"
ARTI_RELEASE="${ARTIFACTORY_RELEASE:-artifactory}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
ARTI_USER="${ARTIFACTORY_ADMIN_USER:-admin}"
ARTI_REPO="${ARTIFACTORY_REPOSITORY:-libs-release-local}"
SYNC_JENKINS="${SYNC_JENKINS:-true}"

ARTI_URL="http://${NODE_IP}:${ARTI_PORT}/artifactory"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
fail() { echo "FAIL: $*" >&2; exit 1; }

patch_env_key() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" ]] || touch "${file}"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

patch_both() {
  patch_env_key "${ENV_FILE}" "$1" "$2"
  patch_env_key "${DOT_ENV}" "$1" "$2"
  ok "$1 set"
}

arti_ping() {
  curl -fsS -m 15 "${ARTI_URL}/api/system/ping" >/dev/null 2>&1
}

wait_artifactory() {
  local n=0
  until arti_ping; do
    n=$((n + 1))
    [[ "${n}" -le 60 ]] || fail "Artifactory not reachable at ${ARTI_URL}/api/system/ping"
    echo "  waiting Artifactory (${n}/60)…"
    sleep 10
  done
  ok "Artifactory UP ${ARTI_URL}"
}

detect_artifactory_nodeport() {
  local svc="${ARTI_RELEASE}-artifactory-nginx"
  [[ -n "$(kubectl get svc -n "${ARTI_NS}" "${svc}" --request-timeout=20s 2>/dev/null)" ]] || return 1
  kubectl get svc -n "${ARTI_NS}" "${svc}" --request-timeout=20s \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null \
    | tr -d '\r\n'
}

ensure_artifactory_release() {
  local existing_np svc="${ARTI_RELEASE}-artifactory-nginx"
  existing_np="$(detect_artifactory_nodeport 2>/dev/null || true)"
  if [[ -n "${existing_np}" ]]; then
    ARTI_PORT="${existing_np}"
    ARTI_URL="http://${NODE_IP}:${ARTI_PORT}/artifactory"
    ok "reuse existing Artifactory NodePort ${ARTI_PORT} from ${svc}"
  fi
  if arti_ping; then
    ok "Artifactory already reachable at ${ARTI_URL}"
    return 0
  fi
  command -v helm >/dev/null 2>&1 || fail "helm required to install Artifactory"
  kubectl get ns "${ARTI_NS}" >/dev/null 2>&1 || kubectl create ns "${ARTI_NS}"
  helm repo add jfrog https://charts.jfrog.io >/dev/null 2>&1 || true
  helm repo update jfrog >/dev/null 2>&1 || true

  local pg_tag=""
  local pg_pod="${ARTI_RELEASE}-postgresql-0"
  if kubectl get pod -n "${ARTI_NS}" "${pg_pod}" >/dev/null 2>&1; then
    pg_tag="$(kubectl get pod -n "${ARTI_NS}" "${pg_pod}" \
      -o jsonpath='{.spec.containers[0].image}' 2>/dev/null | sed -n 's/.*:\([^/]*\)$/\1/p')"
    [[ -n "${pg_tag}" ]] && ok "retain postgresql.image.tag=${pg_tag} for helm upgrade"
  fi

  local helm_extra=()
  if [[ -n "${pg_tag}" ]]; then
    helm_extra+=(--set "postgresql.image.tag=${pg_tag}" --set databaseUpgradeReady=true)
  fi

  local helm_rc=0
  if kubectl get svc -n "${ARTI_NS}" "${svc}" >/dev/null 2>&1; then
    echo "==> helm upgrade --install ${ARTI_RELEASE} (--reuse-values; keep existing NodePort)"
    helm upgrade --install "${ARTI_RELEASE}" jfrog/artifactory \
      -n "${ARTI_NS}" \
      --reuse-values \
      "${helm_extra[@]}" \
      --wait --timeout 15m || helm_rc=$?
  else
    echo "==> helm upgrade --install ${ARTI_RELEASE} (NodePort ${ARTI_PORT})"
    helm upgrade --install "${ARTI_RELEASE}" jfrog/artifactory \
      -n "${ARTI_NS}" \
      --set nginx.service.type=NodePort \
      --set "nginx.service.nodePort=${ARTI_PORT}" \
      --set artifactory.persistence.enabled=false \
      --set postgresql.enabled=true \
      "${helm_extra[@]}" \
      --wait --timeout 15m || helm_rc=$?
  fi
  if [[ "${helm_rc}" -ne 0 ]]; then
    existing_np="$(detect_artifactory_nodeport 2>/dev/null || true)"
    if [[ -n "${existing_np}" ]]; then
      ARTI_PORT="${existing_np}"
      ARTI_URL="http://${NODE_IP}:${ARTI_PORT}/artifactory"
    fi
    if arti_ping; then
      warn "helm upgrade failed (rc=${helm_rc}) but Artifactory ping OK at ${ARTI_URL} — continuing"
    else
      fail "helm upgrade failed and Artifactory not reachable at ${ARTI_URL}"
    fi
  fi
  wait_artifactory
}

read_admin_password() {
  local pw=""
  pw="$(kubectl get secret -n "${ARTI_NS}" "${ARTI_RELEASE}-artifactory" \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  if [[ -z "${pw}" ]]; then
    pw="$(kubectl get secret -n "${ARTI_NS}" "${ARTI_RELEASE}-artifactory-unified-secret" \
      -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  [[ -n "${pw}" ]] || fail "could not read Artifactory admin password from secret"
  printf '%s' "${pw}"
}

ensure_local_repo() {
  local pass="$1"
  local http
  http="$(curl -sS -o /dev/null -w '%{http_code}' -m 20 -u "${ARTI_USER}:${pass}" \
    -X PUT "${ARTI_URL}/api/repositories/${ARTI_REPO}" \
    -H 'Content-Type: application/json' \
    -d "{\"key\":\"${ARTI_REPO}\",\"rclass\":\"local\",\"packageType\":\"generic\"}" 2>/dev/null || echo 000)"
  [[ "${http}" == "200" || "${http}" == "400" ]] || warn "repo create HTTP ${http} (may already exist)"
  ok "repository ${ARTI_REPO}"
}

main() {
  echo "=============================================="
  echo " bootstrap-artifactory-lab"
  echo "=============================================="
  ensure_artifactory_release
  local pass
  pass="$(read_admin_password)"
  ensure_local_repo "${pass}"
  patch_both "ARTIFACTORY_URL" "${ARTI_URL}"
  patch_both "ARTIFACTORY_REPOSITORY" "${ARTI_REPO}"
  patch_both "ARTIFACTORY_USERNAME" "${ARTI_USER}"
  patch_both "ARTIFACTORY_PASSWORD" "${pass}"
  patch_both "NEXT_PUBLIC_ARTIFACTORY_URL" "${ARTI_URL}"
  if [[ "${SYNC_JENKINS}" == "true" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
    set -a
    source "${ENV_FILE}" 2>/dev/null || true
    set +a
    python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force
    ok "Jenkins job parameters synced"
  fi
  echo "=============================================="
  echo "Done. Artifactory: ${ARTI_URL}"
  echo "  User: ${ARTI_USER} / password from cluster secret"
  echo "  Next: bash paas/scripts/lab.sh env-quick"
  echo "=============================================="
}

main "$@"
