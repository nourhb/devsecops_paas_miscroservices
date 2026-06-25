#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DOT_ENV="${REPO_ROOT}/paas/frontend/.env"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
SCALE_MONITORING="${SCALE_MONITORING:-true}"
RUN_DT_BOOTSTRAP="${RUN_DT_BOOTSTRAP:-auto}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }
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

patch_both() {
  local key="$1" value="$2"
  patch_env_key "${ENV_FILE}" "${key}" "${value}"
  patch_env_key "${DOT_ENV}" "${key}" "${value}"
  ok "${key}=${value}"
}

svc_nodeport() {
  local ns="$1" svc="$2" port_name="${3:-}"
  [[ -n "${svc}" ]] || return 1
  kubectl get svc "${svc}" -n "${ns}" >/dev/null 2>&1 || return 1
  if [[ -n "${port_name}" ]]; then
    kubectl get svc "${svc}" -n "${ns}" \
      -o jsonpath="{.spec.ports[?(@.name==\"${port_name}\")].nodePort}" 2>/dev/null
  else
    kubectl get svc "${svc}" -n "${ns}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null
  fi
}

first_running_svc() {
  local ns="$1"
  shift
  local candidate
  for candidate in "$@"; do
    if kubectl get svc "${candidate}" -n "${ns}" >/dev/null 2>&1; then
      printf '%s' "${candidate}"
      return 0
    fi
  done
  return 1
}

scale_monitoring_if_needed() {
  [[ "${SCALE_MONITORING}" == "true" ]] || return 0
  bash "${SCRIPT_DIR}/lab-prometheus-recover.sh" || warn "prometheus recover failed — continuing"
}

ensure_dt_api_key() {
  local api_base="$1"
  local key http
  key="$(grep -E '^DEPENDENCY_TRACK_API_KEY=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -n "${key}" ]]; then
    http="$(curl -sS -o /dev/null -w '%{http_code}' -m 15 \
      -H "X-Api-Key: ${key}" "${api_base}/api/v1/project?pageNumber=1&pageSize=1" 2>/dev/null || echo 000)"
    if [[ "${http}" == "200" ]]; then
      ok "Dependency-Track API key valid"
      return 0
    fi
    warn "DEPENDENCY_TRACK_API_KEY invalid (HTTP ${http})"
  fi
  [[ "${RUN_DT_BOOTSTRAP}" == "false" ]] && return 0
  echo "==> Running dt-bootstrap for API key"
  bash "${SCRIPT_DIR}/bootstrap-dependency-track-lab.sh"
}

main() {
  need_cmd kubectl
  need_cmd curl

  echo "=============================================="
  echo " bootstrap-integrations-lab"
  echo "=============================================="

  scale_monitoring_if_needed

  patch_both "NODE_IP" "${NODE_IP}"
  patch_both "APPS_PUBLIC_LAB_NODE_IP" "${NODE_IP}"

  local np url svc

  svc="$(first_running_svc "${MON_NS}" \
    kube-prometheus-stack-grafana kube-prometheus-grafana grafana 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    np="$(svc_nodeport "${MON_NS}" "${svc}" "http" || svc_nodeport "${MON_NS}" "${svc}")"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "NEXT_PUBLIC_GRAFANA_URL" "http://${NODE_IP}:${np}"
    fi
    patch_both "GRAFANA_PROBE_URL" "http://${svc}.${MON_NS}.svc.cluster.local:80"
  else
    warn "Grafana service not found in ${MON_NS}"
  fi

  svc="$(first_running_svc "${MON_NS}" \
    kube-prometheus-stack-alertmanager alertmanager-kube-prometheus-stack-alertmanager 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    np="$(svc_nodeport "${MON_NS}" "${svc}" "http-web" || svc_nodeport "${MON_NS}" "${svc}")"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "NEXT_PUBLIC_ALERTMANAGER_URL" "http://${NODE_IP}:${np}"
      patch_both "ALERTMANAGER_PROBE_URL" "http://${NODE_IP}:${np}"
    fi
  fi

  svc="$(first_running_svc "${MON_NS}" \
    kube-prometheus-stack-prometheus prometheus-kube-prometheus-stack-prometheus 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    np="$(svc_nodeport "${MON_NS}" "${svc}" "http-web" || svc_nodeport "${MON_NS}" "${svc}")"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "NEXT_PUBLIC_PROMETHEUS_URL" "http://${NODE_IP}:${np}"
    fi
  fi

  svc="$(first_running_svc monitoring \
    elasticsearch-master-elasticsearch-master elasticsearch-master elasticsearch 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    np="$(svc_nodeport monitoring "${svc}" "http" || svc_nodeport monitoring "${svc}")"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "NEXT_PUBLIC_ELASTICSEARCH_URL" "http://${NODE_IP}:${np}"
      patch_both "ELASTICSEARCH_PROBE_URL" "http://${NODE_IP}:${np}"
    fi
  else
    warn "Elasticsearch service not found (may be scaled to 0 — run: bash paas/scripts/lab.sh prometheus)"
  fi

  svc="$(first_running_svc monitoring kibana-kibana kibana 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    np="$(svc_nodeport monitoring "${svc}" "http" || svc_nodeport monitoring "${svc}")"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "NEXT_PUBLIC_KIBANA_URL" "http://${NODE_IP}:${np}"
    fi
  fi

  if kubectl get svc harbor-trivy -n harbor >/dev/null 2>&1; then
    patch_both "TRIVY_PROBE_URL" "http://harbor-trivy.harbor.svc.cluster.local:8080"
    patch_both "HARBOR_TRIVY_INSTALLED" "true"
    np="$(svc_nodeport harbor harbor-trivy 2>/dev/null || true)"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "TRIVY_BASE_URL" "http://${NODE_IP}:${np}"
    else
      patch_both "TRIVY_BASE_URL" "http://harbor-trivy.harbor.svc.cluster.local:8080"
    fi
  fi

  local ingress_port="${APPS_PUBLIC_INGRESS_HTTP_PORT:-30659}"
  patch_both "NEXT_PUBLIC_INGRESS_NGINX_URL" "http://${NODE_IP}:${ingress_port}"
  patch_both "INGRESS_NGINX_PROBE_URL" "http://${NODE_IP}:${ingress_port}"

  if kubectl get ns cert-manager >/dev/null 2>&1; then
    patch_both "CERT_MANAGER_INSTALLED" "true"
  fi

  if kubectl get ns kyverno >/dev/null 2>&1; then
    patch_both "COSIGN_LAB_POLICY" "true"
  fi

  local dt_base
  dt_base="$(grep -E '^DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -z "${dt_base}" ]]; then
    np="$(svc_nodeport dependency-track dtrack-dependency-track-api-server 2>/dev/null || true)"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      dt_base="http://${NODE_IP}:${np}"
      patch_both "DEPENDENCY_TRACK_BASE_URL" "${dt_base}"
      patch_both "NEXT_PUBLIC_DEPENDENCY_TRACK_URL" "${dt_base}"
    fi
  fi
  if [[ -n "${dt_base}" ]]; then
    patch_both "NEXT_PUBLIC_DEPENDENCY_TRACK_URL" "${dt_base}"
    ensure_dt_api_key "${dt_base}"
  fi

  local app_base
  app_base="$(grep -E '^APP_BASE_URL=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -n "${app_base}" ]]; then
    patch_both "ZAP_TARGET_URL" "${app_base}"
  fi

  svc="$(first_running_svc security zap zap-zap 2>/dev/null || true)"
  if [[ -n "${svc}" ]]; then
    np="$(svc_nodeport security "${svc}" "http" || svc_nodeport security "${svc}")"
    if [[ -n "${np}" && "${np}" != "null" ]]; then
      patch_both "NEXT_PUBLIC_OWASP_ZAP_URL" "http://${NODE_IP}:${np}"
    fi
  else
    ok "OWASP ZAP not installed — ZAP_TARGET_URL set for Jenkins DAST only"
  fi

  echo "=============================================="
  echo "Done. Next on VM:"
  echo "  bash paas/scripts/lab.sh env"
  echo "  NO_CACHE=true bash paas/scripts/lab.sh frontend   # if Integrations page unchanged"
  echo "=============================================="
}

main "$@"
