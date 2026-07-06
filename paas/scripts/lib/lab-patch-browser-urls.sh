#!/usr/bin/env bash
# Lab script to patch browser urls on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }

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
  ok "$1=$2"
}

env_val() {
  local key="$1"
  grep -E "^${key}=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"' || true
}

is_browser_url() {
  local url="$1"
  [[ -n "${url}" ]] || return 1
  [[ "${url}" == *".svc"* || "${url}" == *".cluster.local"* ]] && return 1
  [[ "${url}" =~ ^https?:// ]] && return 0
  return 1
}

mirror_public() {
  local pub_key="$1" src_key="$2"
  local existing src
  existing="$(env_val "${pub_key}")"
  if is_browser_url "${existing}"; then
    ok "${pub_key} already set (${existing})"
    return 0
  fi
  src="$(env_val "${src_key}")"
  if is_browser_url "${src}"; then
    patch_both "${pub_key}" "${src}"
    return 0
  fi
  warn "${pub_key} not set and ${src_key} is not browser-reachable"
}

svc_nodeport() {
  local ns="$1" svc="$2" port_name="${3:-}"
  kubectl get svc "${svc}" -n "${ns}" >/dev/null 2>&1 || return 1
  if [[ -n "${port_name}" ]]; then
    kubectl get svc "${svc}" -n "${ns}" \
      -o jsonpath="{.spec.ports[?(@.name==\"${port_name}\")].nodePort}" 2>/dev/null
  else
    kubectl get svc "${svc}" -n "${ns}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null
  fi
}

main() {
  echo "=============================================="
  echo " lab-patch-browser-urls"
  echo "=============================================="

  patch_both "NODE_IP" "${NODE_IP}"
  patch_both "APPS_PUBLIC_LAB_NODE_IP" "${NODE_IP}"

  mirror_public "NEXT_PUBLIC_JENKINS_URL" "JENKINS_BASE_URL"
  mirror_public "NEXT_PUBLIC_JENKINS_PROBE_URL" "JENKINS_BASE_URL"
  mirror_public "NEXT_PUBLIC_SONAR_URL" "SONAR_BASE_URL"
  mirror_public "NEXT_PUBLIC_HARBOR_URL" "HARBOR_BASE_URL"
  mirror_public "NEXT_PUBLIC_DEPENDENCY_TRACK_URL" "DEPENDENCY_TRACK_BASE_URL"

  local harbor_np="${HARBOR_NODEPORT:-30002}"
  if command -v kubectl >/dev/null 2>&1 && kubectl get svc harbor -n harbor >/dev/null 2>&1; then
    np="$(svc_nodeport harbor harbor "http" || svc_nodeport harbor harbor || true)"
    [[ -n "${np}" && "${np}" != "null" ]] && harbor_np="${np}"
    if ! is_browser_url "$(env_val NEXT_PUBLIC_HARBOR_URL)"; then
      patch_both "NEXT_PUBLIC_HARBOR_URL" "http://${NODE_IP}:${harbor_np}"
    fi
  fi

  if command -v kubectl >/dev/null 2>&1 && kubectl get svc argocd-server -n argocd >/dev/null 2>&1; then
    local https_np http_np argo_browser
    https_np="$(kubectl get svc argocd-server -n argocd \
      -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || true)"
    http_np="$(kubectl get svc argocd-server -n argocd \
      -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null || true)"
    if [[ -n "${https_np}" && "${https_np}" != "null" ]]; then
      argo_browser="https://${NODE_IP}:${https_np}"
    elif [[ -n "${http_np}" && "${http_np}" != "null" ]]; then
      argo_browser="http://${NODE_IP}:${http_np}"
    fi
    if [[ -n "${argo_browser:-}" ]]; then
      patch_both "NEXT_PUBLIC_ARGOCD_URL" "${argo_browser}"
    fi
  fi

  if command -v kubectl >/dev/null 2>&1 && kubectl get svc harbor-trivy -n harbor >/dev/null 2>&1; then
    np="$(svc_nodeport harbor harbor-trivy || true)"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "TRIVY_BASE_URL" "http://${NODE_IP}:${np}"
    fi
  fi

  echo "=============================================="
  echo "Browser URLs in ${ENV_FILE}:"
  grep -E '^NEXT_PUBLIC_(JENKINS|SONAR|HARBOR|ARGOCD|PROMETHEUS|GRAFANA|ALERTMANAGER|DEPENDENCY_TRACK)_URL=' "${ENV_FILE}" || true
  echo "=============================================="
}

main "$@"
