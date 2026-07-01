#!/usr/bin/env bash
# Nuclear lab fix: wipe broken Sonar release and install a small 9.9 LTS on master.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
SONAR_RELEASE="${SONAR_HELM_RELEASE:-sonarqube}"
SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"
SONAR_LAB_NODE="${SONAR_LAB_NODE:-master}"

ok() { echo "OK: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

apply_sysctl_all_nodes() {
  echo "==> sysctl vm.max_map_count on every Linux node (DaemonSet — no ssh)"
  kubectl apply --server-side --force-conflicts -f - <<'YAML' >/dev/null
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: paas-sonar-sysctl
  namespace: kube-system
  labels:
    app: paas-sonar-sysctl
spec:
  selector:
    matchLabels:
      app: paas-sonar-sysctl
  template:
    metadata:
      labels:
        app: paas-sonar-sysctl
    spec:
      hostPID: true
      tolerations:
        - operator: Exists
      containers:
        - name: sysctl
          image: busybox:1.36
          command:
            - sh
            - -c
            - sysctl -w vm.max_map_count=524288; sysctl -w fs.file-max=131072; sleep 3600
          securityContext:
            privileged: true
YAML
  sleep 8
  kubectl delete daemonset paas-sonar-sysctl -n kube-system --ignore-not-found --wait=false 2>/dev/null || true
  sudo sysctl -w vm.max_map_count=524288 2>/dev/null || true
  ok "sysctl applied (master + workers via DaemonSet)"
}

wipe_sonar() {
  echo "==> Remove broken Sonar release + PVCs"
  helm uninstall "${SONAR_RELEASE}" -n "${SONAR_NS}" 2>/dev/null || true
  kubectl delete statefulset,deploy,pod,pvc,secret,configmap -n "${SONAR_NS}" --all --ignore-not-found --wait=false 2>/dev/null || true
  kubectl delete namespace "${SONAR_NS}" --ignore-not-found --timeout=120s 2>/dev/null || true
  for _ in $(seq 1 24); do
    kubectl get ns "${SONAR_NS}" >/dev/null 2>&1 || { ok "namespace ${SONAR_NS} gone"; return 0; }
    sleep 5
  done
  die "namespace ${SONAR_NS} still terminating — run: kubectl get ns ${SONAR_NS} -o yaml | grep finalizers"
}

install_sonar() {
  command -v helm >/dev/null 2>&1 || die "helm required"
  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
  helm repo update sonarqube 2>/dev/null || true
  kubectl create namespace "${SONAR_NS}"
  echo "==> helm install ${SONAR_RELEASE} (9.9 LTS community, master only, NodePort ${SONAR_PORT})"
  helm upgrade --install "${SONAR_RELEASE}" sonarqube/sonarqube -n "${SONAR_NS}" \
    --set service.type=NodePort \
    --set "service.nodePort=${SONAR_PORT}" \
    --set community.enabled=true \
    --set "image.tag=9.9.8-community" \
    --set postgresql.enabled=true \
    --set postgresql.primary.persistence.enabled=false \
    --set "postgresql.primary.nodeSelector.kubernetes\.io/hostname=${SONAR_LAB_NODE}" \
    --set monitoringPasscode=paas-lab-monitor \
    --set initSysctl.enabled=false \
    --set initFs.enabled=false \
    --set "nodeSelector.kubernetes\.io/hostname=${SONAR_LAB_NODE}" \
    --set-json 'tolerations=[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]' \
    --set startupProbe.initialDelaySeconds=60 \
    --set startupProbe.periodSeconds=15 \
    --set startupProbe.failureThreshold=40 \
    --set startupProbe.timeoutSeconds=5 \
    --set sonarProperties."sonar\\.web\\.javaOpts"="-Xmx512m -Xms256m" \
    --set sonarProperties."sonar\\.ce\\.javaOpts"="-Xmx512m -Xms256m" \
    --set resources.requests.memory=512Mi \
    --set resources.limits.memory=2Gi \
    --timeout 20m
}

wait_up() {
  local i
  for i in $(seq 1 36); do
    if curl -fsS -m 10 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
      ok "SonarQube UP ${SONAR_URL} (${i} checks)"
      return 0
    fi
    kubectl get pods -n "${SONAR_NS}" -o wide --request-timeout=15s 2>/dev/null | tail -n +2 || true
    echo "  waiting… (${i}/36)"
    sleep 15
  done
  echo "==> last logs"
  local pod
  pod="$(kubectl get pods -n "${SONAR_NS}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
  [[ -n "${pod}" ]] && kubectl logs -n "${SONAR_NS}" "${pod}" -c sonarqube --tail=40 2>/dev/null || true
  die "Sonar not UP at ${SONAR_URL}"
}

main() {
  echo "=============================================="
  echo " Sonar fresh install (wipe + 9.9 LTS on master)"
  echo "=============================================="
  apply_sysctl_all_nodes
  wipe_sonar
  install_sonar
  wait_up
  if [[ -f "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" ]]; then
    echo "==> SONAR_TOKEN bootstrap"
    SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh"
  fi
  echo ""
  echo "Done. UI: ${SONAR_URL}  (admin / SonarQube123! after bootstrap)"
  echo "Next: bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh"
}

main "$@"
