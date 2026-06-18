#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_PORT="${JENKINS_PORT:-8080}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

discover_jenkins_ns() {
  for ns in ${JENKINS_K8S_NAMESPACE:-} cicd jenkins devsecops; do
    [[ -n "${ns}" ]] || continue
    kubectl get ns "${ns}" >/dev/null 2>&1 || continue
    if kubectl get pods -n "${ns}" -o name 2>/dev/null | grep -qi jenkins; then
      echo "${ns}"
      return 0
    fi
    if kubectl get svc -n "${ns}" -o name 2>/dev/null | grep -qi jenkins; then
      echo "${ns}"
      return 0
    fi
  done
  return 1
}

discover_jenkins_service() {
  local ns="$1"
  local svc
  for svc in jenkins-service jenkins jenkins-master; do
    if kubectl get svc -n "${ns}" "${svc}" >/dev/null 2>&1; then
      echo "${svc}"
      return 0
    fi
  done
  kubectl get svc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'jenkins' | head -1
}

discover_jenkins_workload() {
  local ns="$1"
  local kind name
  for kind in statefulset deployment; do
    while IFS= read -r name; do
      [[ -n "${name}" ]] || continue
      echo "${kind} ${name}"
      return 0
    done < <(
      kubectl get "${kind}" -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -iE 'jenkins' || true
    )
  done
  return 1
}

jenkins_endpoints_ready() {
  local ns="$1" svc="$2"
  kubectl get endpoints -n "${ns}" "${svc}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

jenkins_probe_url() {
  local url="$1"
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 "${url}/login" 2>/dev/null || echo "000"
}

ensure_jenkins_env_in_cluster() {
  local ns="$1" svc="$2"
  local in_cluster="http://${svc}.${ns}.svc.cluster.local:${JENKINS_PORT}"
  [[ -f "${ENV_FILE}" ]] || return 0
  if grep -qE '^JENKINS_BASE_URL=.*/(30090|192\.168\.56\.129)' "${ENV_FILE}" 2>/dev/null; then
    echo "==> Hint: frontend pod should use in-cluster Jenkins URL: ${in_cluster}"
    echo "    (NodePort is for browser only; pods use cluster DNS)"
  fi
}

recover_jenkins_workload() {
  local ns="$1"
  local wl
  if ! wl="$(discover_jenkins_workload "${ns}")"; then
    echo "ERROR: no Jenkins StatefulSet/Deployment in namespace ${ns}" >&2
    kubectl get deploy,sts -n "${ns}" 2>/dev/null || true
    return 1
  fi
  local kind="${wl%% *}" name="${wl#* }"
  echo "==> Jenkins workload: ${kind}/${name} -n ${ns}"
  kubectl get pods -n "${ns}" -l "app.kubernetes.io/name=jenkins" -o wide 2>/dev/null \
    || kubectl get pods -n "${ns}" | grep -i jenkins || true

  echo "==> Delete Failed/Evicted Jenkins pods"
  kubectl get pods -n "${ns}" --field-selector=status.phase=Failed -o name 2>/dev/null \
    | grep -i jenkins | xargs -r kubectl delete --wait=false 2>/dev/null || true
  kubectl get pods -n "${ns}" -o jsonpath='{range .items[?(@.status.reason=="Evicted")]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | xargs -r kubectl delete --wait=false 2>/dev/null || true

  echo "==> Rollout restart ${kind}/${name}"
  kubectl rollout restart "${kind}/${name}" -n "${ns}"
  kubectl rollout status "${kind}/${name}" -n "${ns}" --timeout=600s
}

jenkins_recover() {
  echo "=============================================="
  echo " Jenkins recover (namespace cicd/jenkins)"
  echo "=============================================="

  local ns svc
  if ! ns="$(discover_jenkins_ns)"; then
    echo "ERROR: Jenkins namespace not found (tried cicd, jenkins, devsecops)" >&2
    kubectl get ns 2>/dev/null | grep -iE 'cicd|jenkins|devsecops' || true
    return 1
  fi
  echo "==> Jenkins namespace: ${ns}"
  svc="$(discover_jenkins_service "${ns}")"
  if [[ -z "${svc}" ]]; then
    echo "ERROR: Jenkins Service not found in ${ns}" >&2
    kubectl get svc -n "${ns}" 2>/dev/null || true
    return 1
  fi
  echo "==> Jenkins service: ${svc}"
  kubectl get endpoints -n "${ns}" "${svc}" -o wide 2>/dev/null || true
  kubectl get pods -n "${ns}" -o wide 2>/dev/null | grep -i jenkins || kubectl get pods -n "${ns}" -o wide 2>/dev/null || true

  local cluster_ip
  cluster_ip="$(kubectl get svc -n "${ns}" "${svc}" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  if jenkins_endpoints_ready "${ns}" "${svc}"; then
    local hc
    hc="$(jenkins_probe_url "http://${cluster_ip}:${JENKINS_PORT}")"
    if [[ "${hc}" =~ ^(200|403)$ ]]; then
      echo "OK: Jenkins already healthy (cluster IP ${cluster_ip}:${JENKINS_PORT} HTTP ${hc})"
    else
      echo "WARN: endpoints exist but /login HTTP ${hc} — restarting workload"
      recover_jenkins_workload "${ns}"
    fi
  else
    echo "WARN: no endpoints on ${svc} (ECONNREFUSED from PaaS) — restarting Jenkins"
    recover_jenkins_workload "${ns}"
  fi

  echo "==> Wait for endpoints"
  for i in $(seq 1 60); do
    if jenkins_endpoints_ready "${ns}" "${svc}"; then
      break
    fi
    sleep 5
    [[ "${i}" -eq 60 ]] && { echo "ERROR: Jenkins endpoints still empty after 5m" >&2; return 1; }
  done

  local hc_np hc_cl
  hc_np="$(jenkins_probe_url "http://${NODE_IP}:${JENKINS_NODEPORT}")"
  hc_cl="$(jenkins_probe_url "http://${cluster_ip}:${JENKINS_PORT}")"
  echo "==> Probes: NodePort :${JENKINS_NODEPORT} HTTP ${hc_np}; cluster ${cluster_ip}:${JENKINS_PORT} HTTP ${hc_cl}"
  if [[ ! "${hc_cl}" =~ ^(200|403)$ ]]; then
    echo "ERROR: Jenkins still not responding after recover" >&2
    kubectl describe pods -n "${ns}" 2>/dev/null | grep -iE 'jenkins|Events:' -A3 | tail -40 || true
    return 1
  fi

  ensure_jenkins_env_in_cluster "${ns}" "${svc}"

  if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
    echo "==> Probe from frontend pod"
    local in_cluster="http://${svc}.${ns}.svc.cluster.local:${JENKINS_PORT}"
    kubectl exec -n "${PAAS_NS}" deploy/frontend -- wget -q -O /dev/null --timeout=10 "${in_cluster}/login" 2>/dev/null \
      && echo "OK: frontend pod reaches ${in_cluster}" \
      || echo "WARN: frontend pod cannot reach ${in_cluster} — run: bash paas/scripts/lab.sh env"
  fi

  echo "=============================================="
  echo "OK: Jenkins is up. Next:"
  echo "  bash paas/scripts/lab.sh env"
  echo "  bash paas/scripts/lab.sh jenkins   # sync pipeline job"
  echo "=============================================="
}

case "${1:-recover}" in
  recover) jenkins_recover ;;
  *)
    echo "usage: lab-jenkins-recover.sh [recover]" >&2
    exit 1
    ;;
esac
