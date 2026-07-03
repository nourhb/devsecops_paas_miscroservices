#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
SONAR_VALUES="${SONAR_HELM_VALUES:-${REPO_ROOT}/paas/k8s-manifests/lab/sonarqube-helm-lab-values.yaml}"

lab_sonar_helm_upgrade() {
  local release="${1:-sonarqube}"
  local ns="${2:-sonarqube}"
  local node="${3:-master}"
  local port="${4:-30900}"

  command -v helm >/dev/null 2>&1 || return 1
  [[ -f "${SONAR_VALUES}" ]] || {
    echo "FAIL: missing ${SONAR_VALUES}" >&2
    return 1
  }
  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
  helm repo update sonarqube 2>/dev/null || true
  if [[ -f "${SCRIPT_DIR}/lab-k3s-ensure.sh" ]]; then
    export LAB_K3S_WAIT_LOOPS="${LAB_K3S_WAIT_LOOPS:-24}"
    export LAB_K3S_WAIT_SEC="${LAB_K3S_WAIT_SEC:-5}"
    bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || {
      echo "FAIL: k3s API unreachable — sudo bash paas/scripts/lab.sh k3s-unstick" >&2
      return 1
    }
  fi
  kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create namespace "${ns}"

  echo "==> helm upgrade ${release} (9.9 LTS, embedded H2, ${node}, NodePort ${port}, httpGet probes)"
  helm upgrade --install "${release}" sonarqube/sonarqube -n "${ns}" \
    --reset-values \
    -f "${SONAR_VALUES}" \
    --set "service.nodePort=${port}" \
    --set "nodeSelector.kubernetes\.io/hostname=${node}" \
    --set readinessProbe.exec=null \
    --set livenessProbe.exec=null \
    --timeout 20m
}

lab_sonar_pod_restarts() {
  local ns="${1:-sonarqube}"
  local pod
  pod="$(kubectl get pods -n "${ns}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
  [[ -n "${pod}" ]] || { echo 0; return 0; }
  kubectl get pod -n "${ns}" "${pod}" -o jsonpath='{.status.containerStatuses[?(@.name=="sonarqube")].restartCount}' 2>/dev/null || echo 0
}

lab_sonar_repair_crash_loop() {
  local ns="${1:-sonarqube}"
  local release="${2:-sonarqube}"
  local node="${3:-master}"
  local port="${4:-30900}"
  local pod restarts
  restarts="$(lab_sonar_pod_restarts "${ns}")"
  pod="$(kubectl get pods -n "${ns}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
  echo "WARN: Sonar pod restarts=${restarts} — helm repair (httpGet probes, 256m heap, no curl exec)"
  [[ -n "${pod}" ]] && kubectl describe pod -n "${ns}" "${pod}" 2>/dev/null | tail -15 || true
  lab_sonar_helm_upgrade "${release}" "${ns}" "${node}" "${port}"
  [[ -n "${pod}" ]] && kubectl delete pod -n "${ns}" "${pod}" --wait=false 2>/dev/null || true
  sleep 30
}
