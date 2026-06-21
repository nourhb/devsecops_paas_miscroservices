#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_SVC="${ARGOCD_SVC:-argocd-server}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
ARGOCD_USERNAME="${ARGOCD_USERNAME:-admin}"
SYNC_JENKINS="${SYNC_JENKINS:-true}"

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 required"
}

patch_env_key() {
  local file="$1" key="$2" value="$3"
  [[ -f "${file}" ]] || touch "${file}"
  if grep -qE "^${key}=" "${file}"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${file}"
  else
    echo "${key}=${value}" >> "${file}"
  fi
}

discover_service_port() {
  local name="$1"
  local port
  port="$(kubectl get svc "${ARGOCD_SVC}" -n "${ARGOCD_NS}" \
    -o jsonpath="{.spec.ports[?(@.name==\"${name}\")].port}" 2>/dev/null || true)"
  [[ -n "${port}" && "${port}" != "null" ]] || return 1
  printf '%s' "${port}"
}

discover_in_cluster_url() {
  local https_port http_port
  https_port="$(discover_service_port https || true)"
  http_port="$(discover_service_port http || true)"
  if [[ -n "${https_port}" ]]; then
    echo "https://${ARGOCD_SVC}.${ARGOCD_NS}.svc.cluster.local:${https_port}"
    return 0
  fi
  if [[ -n "${http_port}" ]]; then
    echo "http://${ARGOCD_SVC}.${ARGOCD_NS}.svc.cluster.local:${http_port}"
    return 0
  fi
  fail "${ARGOCD_SVC} has no http/https port in ${ARGOCD_NS}"
}

discover_nodeport_url() {
  local https_np http_np
  https_np="$(kubectl get svc "${ARGOCD_SVC}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
  if [[ -n "${https_np}" && "${https_np}" != "null" ]]; then
    echo "https://${NODE_IP}:${https_np}"
    return 0
  fi
  http_np="$(kubectl get svc "${ARGOCD_SVC}" -n "${ARGOCD_NS}" \
    -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || true)"
  if [[ -n "${http_np}" && "${http_np}" != "null" ]]; then
    echo "http://${NODE_IP}:${http_np}"
    return 0
  fi
  return 1
}

read_admin_password() {
  if [[ -n "${ARGOCD_PASSWORD:-}" ]]; then
    printf '%s' "${ARGOCD_PASSWORD}"
    return 0
  fi
  kubectl -n "${ARGOCD_NS}" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d
}

argocd_login_verify() {
  local base="$1" user="$2" pass="$3"
  local resp http
  resp="$(curl -sk -m 30 -w $'\n__HTTP__%{http_code}' -X POST "${base}/api/v1/session" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"${user}\",\"password\":\"${pass}\"}")"
  http="${resp##*$'\n__HTTP__'}"
  resp="${resp%$'\n__HTTP__'*}"
  [[ "${http}" == "200" ]] || fail "Argo CD login HTTP ${http} at ${base}: ${resp}"
  python3 -c 'import json,sys; t=json.load(sys.stdin).get("token",""); sys.exit(0 if t else 1)' <<<"${resp}" \
    || fail "Argo CD login returned no session token"
  ok "login verified at ${base}"
}

sync_env_files() {
  local api_base="$1" password="$2"
  for f in "${ENV_FILE}" "${DOT_ENV}"; do
    patch_env_key "${f}" "ARGOCD_BASE_URL" "${api_base}"
    patch_env_key "${f}" "ARGOCD_USERNAME" "${ARGOCD_USERNAME}"
    patch_env_key "${f}" "ARGOCD_PASSWORD" "${password}"
    patch_env_key "${f}" "ARGOCD_TLS_SKIP_VERIFY" "true"
    ok "updated ${f}"
  done
  if [[ "${SYNC_JENKINS}" == "true" ]] && [[ -f "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" ]]; then
    python3 "${REPO_ROOT}/paas/scripts/lib/create_jenkins_paas_deploy_job.py" --params-only --force
    ok "Jenkins job parameters synced"
  fi
}

main() {
  need_cmd kubectl
  need_cmd curl
  need_cmd python3

  echo "=============================================="
  echo " bootstrap-argocd-lab"
  echo "=============================================="

  kubectl get svc "${ARGOCD_SVC}" -n "${ARGOCD_NS}" >/dev/null 2>&1 \
    || fail "${ARGOCD_SVC} not found in namespace ${ARGOCD_NS}"

  local in_cluster probe_base password
  in_cluster="$(discover_in_cluster_url)"
  probe_base="$(discover_nodeport_url || echo "${in_cluster}")"
  password="$(read_admin_password)"
  [[ -n "${password}" ]] || fail "could not read admin password (set ARGOCD_PASSWORD or check argocd-initial-admin-secret)"

  argocd_login_verify "${probe_base}" "${ARGOCD_USERNAME}" "${password}"
  ok "PaaS frontend will use in-cluster API ${in_cluster}"

  sync_env_files "${in_cluster}" "${password}"

  echo "=============================================="
  echo "Done. Next on VM:"
  echo "  bash paas/scripts/lab.sh env"
  echo "  Refresh Integrations → Delivery checklist (Argo CD should be Ready)"
  echo "Optional UI URL (browser): ${probe_base}"
  echo "=============================================="
}

main "$@"
