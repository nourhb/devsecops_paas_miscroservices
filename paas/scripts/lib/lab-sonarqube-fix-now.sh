#!/usr/bin/env bash
# Fix Sonar helm: drop broken plugins.install=[], httpGet probes (no curl), wait for UP.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

NODE_IP="${NODE_IP:-192.168.56.129}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
SONAR_NS="${SONAR_NS:-sonarqube}"
SONAR_RELEASE="${SONAR_HELM_RELEASE:-sonarqube}"
SONAR_URL="http://${NODE_IP}:${SONAR_PORT}"
SONAR_LAB_NODE="${SONAR_LAB_NODE:-master}"
SONAR_VALUES="${SONAR_HELM_VALUES:-${REPO_ROOT}/paas/k8s-manifests/lab/sonarqube-helm-lab-values.yaml}"

ok() { echo "OK: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

sonar_pod_restarts() {
  local pod
  pod="$(kubectl get pods -n "${SONAR_NS}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
  [[ -n "${pod}" ]] || { echo 0; return 0; }
  kubectl get pod -n "${SONAR_NS}" "${pod}" -o jsonpath='{.status.containerStatuses[?(@.name=="sonarqube")].restartCount}' 2>/dev/null || echo 0
}

sonar_helm_upgrade_lab() {
  command -v helm >/dev/null 2>&1 || die "helm not installed"
  helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
  helm repo update sonarqube 2>/dev/null || true
  export LAB_K3S_WAIT_LOOPS="${LAB_K3S_WAIT_LOOPS:-36}"
  export LAB_K3S_WAIT_SEC="${LAB_K3S_WAIT_SEC:-5}"
  bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || die "k3s API down — sudo bash paas/scripts/lab.sh k3s-unstick"
  kubectl get ns "${SONAR_NS}" >/dev/null 2>&1 || kubectl create namespace "${SONAR_NS}"

  local -a helm_args=(
    upgrade --install "${SONAR_RELEASE}" sonarqube/sonarqube -n "${SONAR_NS}"
    --reset-values
    -f "${SONAR_VALUES}"
    --set "service.nodePort=${SONAR_PORT}"
    --set "nodeSelector.kubernetes\.io/hostname=${SONAR_LAB_NODE}"
    --set readinessProbe.exec=null
    --set livenessProbe.exec=null
    --timeout 20m
  )

  echo "==> helm upgrade ${SONAR_RELEASE} (httpGet/tcp probes; exec=null)"
  if helm "${helm_args[@]}" 2>&1; then
    return 0
  fi

  echo "WARN: helm upgrade failed (often StatefulSet probe merge) — uninstall + fresh install (keeps PVC)"
  helm uninstall "${SONAR_RELEASE}" -n "${SONAR_NS}" 2>/dev/null || true
  kubectl delete statefulset,deploy,pod -n "${SONAR_NS}" --all --ignore-not-found --wait=false 2>/dev/null || true
  sleep 10
  bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || die "k3s API down after sonar uninstall"
  echo "==> helm install ${SONAR_RELEASE} (fresh)"
  helm "${helm_args[@]}"
}

echo "=============================================="
echo " lab-sonarqube-fix-now"
echo "=============================================="

mkdir -p "$(dirname "${SONAR_VALUES}")"
cat > "${SONAR_VALUES}" <<'YAML'
community:
  enabled: true
image:
  tag: 9.9.8-community
postgresql:
  enabled: false
persistence:
  enabled: true
  storageClass: local-path
  accessMode: ReadWriteOnce
  size: 2Gi
  annotations:
    helm.sh/resource-policy: keep
    paas.lab/retain: "true"
monitoringPasscode: paas-lab-monitor
initSysctl:
  enabled: false
initFs:
  enabled: false
prometheusExporter:
  enabled: false
service:
  type: NodePort
  nodePort: 30900
nodeSelector:
  kubernetes.io/hostname: master
tolerations:
  - key: node-role.kubernetes.io/control-plane
    operator: Exists
    effect: NoSchedule
  - key: node-role.kubernetes.io/master
    operator: Exists
    effect: NoSchedule
startupProbe:
  initialDelaySeconds: 120
  periodSeconds: 20
  failureThreshold: 90
  timeoutSeconds: 10
readinessProbe:
  exec: null
  httpGet:
    path: /api/system/status
    port: http
  initialDelaySeconds: 120
  periodSeconds: 20
  failureThreshold: 30
  timeoutSeconds: 10
livenessProbe:
  exec: null
  tcpSocket:
    port: http
  initialDelaySeconds: 300
  periodSeconds: 60
  failureThreshold: 20
  timeoutSeconds: 5
sonarProperties:
  sonar.web.javaOpts: "-Xmx256m -Xms128m -XX:+UseSerialGC"
  sonar.ce.javaOpts: "-Xmx256m -Xms128m -XX:+UseSerialGC"
resources:
  requests:
    memory: 256Mi
    cpu: 100m
  limits:
    memory: 1280Mi
    cpu: "1"
YAML
ok "wrote ${SONAR_VALUES}"

lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
sudo sysctl -w vm.max_map_count=524288 2>/dev/null || true

if curl -fsS -m 8 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
  ok "Sonar already UP at ${SONAR_URL}"
  exit 0
fi

sonar_helm_upgrade_lab

echo "==> recycle Sonar pod"
kubectl delete pod -n "${SONAR_NS}" sonarqube-sonarqube-0 --ignore-not-found --wait=false 2>/dev/null || true

echo "==> wait for UP (max ~20 min on 8GB lab — do not Ctrl+C)"
for i in $(seq 1 80); do
  if curl -fsS -m 12 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -qE '"status":"(UP|DB_MIGRATION_NEEDED|DB_MIGRATION_RUNNING)"'; then
    ok "SonarQube UP ${SONAR_URL} (${i} checks)"
    if [[ -f "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" ]]; then
      SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" || true
    fi
    exit 0
  fi
  pod="$(kubectl get pods -n "${SONAR_NS}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
  if [[ -n "${pod}" ]]; then
    restarts="$(sonar_pod_restarts)"
    echo "  [${i}/80] pod=${pod} restarts=${restarts}"
    if kubectl describe pod -n "${SONAR_NS}" "${pod}" 2>/dev/null | tail -5 | grep -q 'curl: not found'; then
      die "helm still has curl exec probes — copy paas/scripts/lib/lab-sonarqube-fix-now.sh from dev machine and re-run"
    fi
  else
    echo "  [${i}/80] waiting for pod…"
  fi
  sleep 15
done

die "Sonar not UP — SONAR_FORCE_WIPE=1 bash paas/scripts/lab.sh sonarqube"
