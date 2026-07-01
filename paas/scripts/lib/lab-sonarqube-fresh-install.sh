#!/usr/bin/env bash
# Nuclear lab fix: wipe broken Sonar release and install a small 9.9 LTS on master.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"
# shellcheck source=lab-sonarqube-helm-lab.sh
source "${SCRIPT_DIR}/lab-sonarqube-helm-lab.sh"
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
  lab_sonar_helm_upgrade "${SONAR_RELEASE}" "${SONAR_NS}" "${SONAR_LAB_NODE}" "${SONAR_PORT}"
}

wait_up() {
  local i pod phase ready restarts repaired=0
  for i in $(seq 1 48); do
    if curl -fsS -m 10 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
      ok "SonarQube UP ${SONAR_URL} (${i} checks)"
      return 0
    fi
    kubectl get pods -n "${SONAR_NS}" -o wide --request-timeout=15s 2>/dev/null | tail -n +2 || true
    pod="$(kubectl get pods -n "${SONAR_NS}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
    if [[ -n "${pod}" ]]; then
      phase="$(kubectl get pod -n "${SONAR_NS}" "${pod}" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      ready="$(kubectl get pod -n "${SONAR_NS}" "${pod}" -o jsonpath='{.status.containerStatuses[?(@.name=="sonarqube")].ready}' 2>/dev/null || true)"
      restarts="$(lab_sonar_pod_restarts "${SONAR_NS}")"
      if [[ "${restarts}" -ge 3 ]] && [[ "${repaired}" -eq 0 ]]; then
        lab_sonar_repair_crash_loop "${SONAR_NS}" "${SONAR_RELEASE}" "${SONAR_LAB_NODE}" "${SONAR_PORT}"
        repaired=1
        continue
      fi
      if [[ "${ready}" != "true" ]] && [[ "${phase}" == "Running" ]] && (( i % 4 == 0 )); then
        kubectl logs -n "${SONAR_NS}" "${pod}" -c sonarqube --tail=5 2>/dev/null || true
        echo "  restarts=${restarts} (>=3 triggers auto-repair once)"
      fi
    fi
    echo "  waiting… (${i}/48 — 8GB lab: 10–20 min; do not Ctrl+C; skip k3s-unstick while waiting)"
    sleep 15
  done
  echo "==> last logs"
  pod="$(kubectl get pods -n "${SONAR_NS}" -o name 2>/dev/null | grep sonarqube-sonarqube | head -1 | sed 's|pod/||' || true)"
  [[ -n "${pod}" ]] && kubectl describe pod -n "${SONAR_NS}" "${pod}" 2>/dev/null | tail -25 || true
  [[ -n "${pod}" ]] && kubectl logs -n "${SONAR_NS}" "${pod}" -c sonarqube --tail=40 2>/dev/null || true
  die "Sonar not UP — run: SONAR_FORCE_WIPE=1 bash paas/scripts/lab.sh sonarqube"
}

sonar_already_installed() {
  kubectl get statefulset sonarqube-sonarqube -n "${SONAR_NS}" >/dev/null 2>&1 \
    || kubectl get deploy -n "${SONAR_NS}" -l app=sonarqube >/dev/null 2>&1
}

main() {
  echo "=============================================="
  echo " Sonar fresh install (wipe + 9.9 LTS on master)"
  echo "=============================================="
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  echo "==> k3s API"
  export LAB_K3S_WAIT_LOOPS=24 LAB_K3S_WAIT_SEC=5
  bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || die "k3s API down — k3s kubectl get nodes (do NOT k3s-unstick if nodes Ready)"

  if curl -fsS -m 8 "${SONAR_URL}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
    ok "Sonar already UP at ${SONAR_URL}"
    if [[ -f "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" ]]; then
      SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh"
    fi
    exit 0
  fi

  if [[ "${SONAR_FORCE_WIPE:-}" == "1" ]]; then
    apply_sysctl_all_nodes
    wipe_sonar
    install_sonar
  elif sonar_already_installed; then
    echo "==> Sonar already on cluster — skip wipe (wait/repair only)"
    restarts="$(lab_sonar_pod_restarts "${SONAR_NS}")"
    if [[ "${restarts}" -ge 3 ]]; then
      lab_sonar_repair_crash_loop "${SONAR_NS}" "${SONAR_RELEASE}" "${SONAR_LAB_NODE}" "${SONAR_PORT}"
    fi
  else
    apply_sysctl_all_nodes
    wipe_sonar
    install_sonar
  fi

  wait_up
  if [[ -f "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh" ]]; then
    echo "==> SONAR_TOKEN bootstrap"
    SYNC_JENKINS=false PAAS_SYNC_K8S_ENV=false bash "${SCRIPT_DIR}/bootstrap-sonarqube-lab.sh"
  fi
  echo ""
  echo "Done. UI: ${SONAR_URL}  (admin / SonarQube123! after bootstrap)"
  echo "Next: trigger NEW paas-deploy build"
}

main "$@"
