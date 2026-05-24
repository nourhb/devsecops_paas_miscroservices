#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"

upsert_env() {
  local key="$1"
  local val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "WARN: missing ${ENV_FILE}" >&2; return 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

remove_env() {
  local key="$1"
  [[ -f "${ENV_FILE}" ]] || return 0
  sed -i "/^${key}=/d" "${ENV_FILE}" 2>/dev/null || true
}

ns_ready() {
  kubectl get ns "$1" >/dev/null 2>&1
}

svc_nodeport_url() {
  local ns="$1" svc="$2" port="${3:-}"
  local np=""
  if [[ -n "${port}" ]]; then
    np="$(kubectl get svc -n "${ns}" "${svc}" -o jsonpath="{.spec.ports[?(@.port==${port})].nodePort}" 2>/dev/null || true)"
    [[ -z "${np}" ]] && np="$(kubectl get svc -n "${ns}" "${svc}" -o jsonpath="{.spec.ports[?(@.name=='${port}')].nodePort}" 2>/dev/null || true)"
  fi
  [[ -z "${np}" ]] && np="$(kubectl get svc -n "${ns}" "${svc}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -n "${np}" && "${np}" != "null" ]]; then
    echo "http://${NODE_IP}:${np}"
  fi
}

svc_has_endpoints() {
  kubectl get endpoints -n "$1" "$2" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

wire_if_url() {
  local key="$1" url="$2"
  if [[ -n "${url}" ]]; then
    upsert_env "${key}" "${url}"
    echo "  + ${key}=${url}"
  fi
}

echo "=== Wire optional integrations (discover NodePorts / cluster services) ==="

if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl not available — skip"
  exit 0
fi

upsert_env POLICY_ENGINE "${POLICY_ENGINE:-kyverno}"
upsert_env BUILD_BACKEND "${BUILD_BACKEND:-jenkins}"

if ns_ready monitoring; then
  for svc in kube-prometheus-stack-prometheus prometheus-service prometheus-operated; do
    u="$(svc_nodeport_url monitoring "${svc}" 9090)"
    [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_PROMETHEUS_URL "${u}" && wire_if_url PROMETHEUS_BASE_URL "${u}" && break
  done
  for svc in kube-prometheus-stack-alertmanager alertmanager-operated alertmanager; do
    u="$(svc_nodeport_url monitoring "${svc}" 9093)"
    [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_ALERTMANAGER_URL "${u}" && break
  done
  for svc in kube-prometheus-stack-kube-state-metrics kube-state-metrics; do
    u="$(svc_nodeport_url monitoring "${svc}" 8080)"
    [[ -z "${u}" ]] && u="$(svc_nodeport_url monitoring "${svc}")"
    [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_KUBE_STATE_METRICS_URL "${u}" && break
  done
  for svc in kube-prometheus-stack-prometheus-node-exporter prometheus-node-exporter node-exporter; do
    u="$(svc_nodeport_url monitoring "${svc}" 9100)"
    [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_NODE_EXPORTER_UI_URL "${u}" && break
  done
  if [[ -z "$(grep -E '^NEXT_PUBLIC_NODE_EXPORTER_UI_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)" ]]; then
    wire_if_url NEXT_PUBLIC_NODE_EXPORTER_UI_URL "http://${NODE_IP}:9100"
  fi
  for svc in kibana-kibana kibana monitoring-kibana; do
    if svc_has_endpoints monitoring "${svc}"; then
      u="$(svc_nodeport_url monitoring "${svc}" 5601)"
      [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_KIBANA_URL "${u}" && break
    fi
  done
fi

if ns_ready ingress-nginx; then
  u="$(svc_nodeport_url ingress-nginx ingress-nginx-controller 80)"
  [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_INGRESS_NGINX_URL "${u}" && wire_if_url INGRESS_NGINX_PROBE_URL "${u}"
fi
if ns_ready kube-system; then
  u="$(svc_nodeport_url kube-system traefik 80)"
  [[ -z "${u}" ]] && u="$(svc_nodeport_url kube-system traefik 8080)"
  if [[ -n "${u}" ]]; then
    grep -q '^NEXT_PUBLIC_INGRESS_NGINX_URL=' "${ENV_FILE}" 2>/dev/null || wire_if_url NEXT_PUBLIC_INGRESS_NGINX_URL "${u}"
    grep -q '^INGRESS_NGINX_PROBE_URL=' "${ENV_FILE}" 2>/dev/null || wire_if_url INGRESS_NGINX_PROBE_URL "${u}"
  fi
fi

if ns_ready cert-manager; then
  upsert_env CERT_MANAGER_INSTALLED "true"
  wire_if_url CERT_MANAGER_PROBE_URL "http://cert-manager-webhook.cert-manager.svc.cluster.local:443"
fi

if ns_ready kubewarden; then
  upsert_env KUBEWARDEN_INSTALLED "true"
  for svc in kubewarden-policy-server policy-server; do
    if svc_has_endpoints kubewarden "${svc}"; then
      wire_if_url NEXT_PUBLIC_KUBEWARDEN_UI_URL "https://${svc}.kubewarden.svc.cluster.local"
      break
    fi
  done
fi

if ns_ready gatekeeper-system; then
  upsert_env GATEKEEPER_INSTALLED "true"
  u="$(svc_nodeport_url gatekeeper-system gatekeeper-controller-manager-metrics 8888)"
  [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_GATEKEEPER_DASHBOARD_URL "${u}"
fi

if ns_ready tekton-pipelines; then
  upsert_env TEKTON_INSTALLED "true"
  for svc in tekton-dashboard dashboard; do
    u="$(svc_nodeport_url tekton-pipelines "${svc}" 9097)"
    [[ -z "${u}" ]] && u="$(svc_nodeport_url tekton-pipelines "${svc}")"
    [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_TEKTON_DASHBOARD_URL "${u}" && break
  done
fi

if ns_ready vault; then
  for svc in vault vault-active vault-ui; do
    if kubectl get svc -n vault "${svc}" >/dev/null 2>&1; then
      u="$(svc_nodeport_url vault "${svc}" 8200)"
      [[ -z "${u}" ]] && u="http://vault.vault.svc.cluster.local:8200"
      wire_if_url VAULT_ADDR "${u}"
      wire_if_url NEXT_PUBLIC_VAULT_UI_URL "${u}"
      break
    fi
  done
fi

if ns_ready portainer; then
  for svc in portainer portainer-agent; do
    u="$(svc_nodeport_url portainer "${svc}" 9000)"
    [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_PORTAINER_URL "${u}" && break
  done
fi

if ns_ready calico-system || ns_ready tigera-operator; then
  upsert_env CALICO_INSTALLED "true"
  wire_if_url NEXT_PUBLIC_CALICO_OR_TIGERA_URL "https://www.tigera.io/project-calico/"
elif ns_ready kube-system && kubectl get ds -n kube-system calico-node >/dev/null 2>&1; then
  upsert_env CALICO_INSTALLED "true"
fi

if ns_ready security && svc_has_endpoints security zap; then
  u="$(svc_nodeport_url security zap 8080)"
  [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_OWASP_ZAP_URL "${u}"
else
  remove_env NEXT_PUBLIC_OWASP_ZAP_URL
fi

if ns_ready devtools; then
  u="$(svc_nodeport_url devtools nexus-nexus-repository-manager 8081)"
  [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_NEXUS_URL "${u}"
  u="$(svc_nodeport_url devtools artifactory 8082)"
  [[ -n "${u}" ]] && wire_if_url NEXT_PUBLIC_ARTIFACTORY_URL "${u}" && wire_if_url ARTIFACTORY_URL "${u}"
fi

if ns_ready opa || ns_ready opa-system; then
  ns_opa="opa"
  ns_ready opa-system && ns_opa="opa-system"
  for svc in opa opa-server; do
    u="$(svc_nodeport_url "${ns_opa}" "${svc}" 8181)"
    [[ -n "${u}" ]] && wire_if_url OPA_EVAL_URL "${u}/v1/data" && break
  done
fi

grep -q '^COSIGN_PUBLIC_KEY=.*REPLACE' "${ENV_FILE}" 2>/dev/null && remove_env COSIGN_PUBLIC_KEY
if grep -qE '^COSIGN_ENFORCE_SIGNED=true' "${ENV_FILE}" 2>/dev/null; then
  upsert_env COSIGN_LAB_POLICY "true"
fi

echo "Done. Sync: ENV_FILE=${ENV_FILE} bash paas/scripts/sync-paas-frontend-env-k8s.sh"
