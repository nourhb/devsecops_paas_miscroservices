#!/usr/bin/env bash
# Shared SonarQube helm values for 8GB lab (embedded H2, low heap, no liveness kill).
set -euo pipefail

lab_sonar_helm_upgrade() {
  local release="${1:-sonarqube}"
  local ns="${2:-sonarqube}"
  local node="${3:-master}"
  local port="${4:-30900}"

  command -v helm >/dev/null 2>&1 || return 1
  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
  helm repo update sonarqube 2>/dev/null || true
  kubectl get ns "${ns}" >/dev/null 2>&1 || kubectl create namespace "${ns}"

  echo "==> helm upgrade ${release} (9.9 LTS, embedded H2, master, NodePort ${port}, 8GB-lab tuning)"
  helm upgrade --install "${release}" sonarqube/sonarqube -n "${ns}" \
    --set service.type=NodePort \
    --set "service.nodePort=${port}" \
    --set community.enabled=true \
    --set "image.tag=9.9.8-community" \
    --set postgresql.enabled=false \
    --set monitoringPasscode=paas-lab-monitor \
    --set initSysctl.enabled=false \
    --set initFs.enabled=false \
    --set 'plugins.install=[]' \
    --set prometheusExporter.enabled=false \
    --set livenessProbe.enabled=false \
    --set "nodeSelector.kubernetes\.io/hostname=${node}" \
    --set-json 'tolerations=[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]' \
    --set startupProbe.initialDelaySeconds=120 \
    --set startupProbe.periodSeconds=20 \
    --set startupProbe.failureThreshold=90 \
    --set startupProbe.timeoutSeconds=5 \
    --set sonarProperties."sonar\\.web\\.javaOpts"="-Xmx256m -Xms128m -XX:+UseSerialGC" \
    --set sonarProperties."sonar\\.ce\\.javaOpts"="-Xmx256m -Xms128m -XX:+UseSerialGC" \
    --set resources.requests.memory=256Mi \
    --set resources.requests.cpu=100m \
    --set resources.limits.memory=1280Mi \
    --set resources.limits.cpu=1 \
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
  echo "WARN: Sonar pod restarts=${restarts} — helm repair (embedded H2, liveness off, 256m heap)"
  [[ -n "${pod}" ]] && kubectl describe pod -n "${ns}" "${pod}" 2>/dev/null | tail -15 || true
  lab_sonar_helm_upgrade "${release}" "${ns}" "${node}" "${port}"
  [[ -n "${pod}" ]] && kubectl delete pod -n "${ns}" "${pod}" --wait=false 2>/dev/null || true
  sleep 30
}
