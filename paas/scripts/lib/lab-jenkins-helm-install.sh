#!/usr/bin/env bash
# Install or repair Jenkins via helm (cicd namespace, NodePort :30090).
# Avoids helm --wait timeouts on slow lab VMs: apply manifests, then poll pod + HTTP.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_RELEASE="${JENKINS_HELM_RELEASE:-jenkins}"
export KUBECONFIG="${KUBECONFIG:-${HOME}/.kube/config}"

log() { echo "[jenkins-install] $*"; }

jenkins_http_code() {
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
    "http://${NODE_IP}:${JENKINS_NODEPORT}/login" 2>/dev/null || echo "000"
}

jenkins_pod_ready() {
  kubectl get pods -n "${JENKINS_NS}" -l app.kubernetes.io/component=jenkins-controller \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True
}

jenkins_init_failing() {
  local reason
  reason="$(kubectl get pods -n "${JENKINS_NS}" jenkins-0 \
    -o jsonpath='{.status.initContainerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  [[ "${reason}" =~ ^(CrashLoopBackOff|Error|ImagePullBackOff)$ ]] && return 0
  reason="$(kubectl get pods -n "${JENKINS_NS}" jenkins-0 \
    -o jsonpath='{.status.initContainerStatuses[0].state.terminated.reason}' 2>/dev/null || true)"
  [[ "${reason}" == Error ]] && return 0
  kubectl get pods -n "${JENKINS_NS}" jenkins-0 \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null | grep -q '^Init:' && return 0
  return 1
}

jenkins_pvc_name() {
  kubectl get pvc -n "${JENKINS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'jenkins' | head -1
}

jenkins_pvc_host_info() {
  local pvc="${1:-}"
  [[ -n "${pvc}" ]] || pvc="$(jenkins_pvc_name)"
  [[ -n "${pvc}" ]] || return 1
  local pv path node
  pv="$(kubectl get pvc -n "${JENKINS_NS}" "${pvc}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  [[ -n "${pv}" ]] || return 1
  path="$(kubectl get pv "${pv}" -o jsonpath='{.spec.local.path}' 2>/dev/null || true)"
  [[ -n "${path}" ]] || path="$(kubectl get pv "${pv}" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || true)"
  node="$(kubectl get pv "${pv}" -o jsonpath='{.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[?(@.key=="kubernetes.io/hostname")].values[0]}' 2>/dev/null || true)"
  [[ -z "${node}" ]] && node="$(kubectl get pods -n "${JENKINS_NS}" jenkins-0 -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  echo "${pvc}|${pv}|${path}|${node}"
}

fix_jenkins_pvc_permissions() {
  local info pvc path node host worker_ip
  info="$(jenkins_pvc_host_info)" || { log "no Jenkins PVC found"; return 1; }
  IFS='|' read -r pvc _ path node <<<"${info}"
  log "PVC ${pvc} on node=${node} path=${path}"
  [[ -n "${path}" ]] || return 1

  host="$(hostname -s 2>/dev/null || hostname)"
  if [[ "${node}" == "${host}" || -d "${path}" ]]; then
    log "chown 1000:1000 on master (${path})"
    sudo chown -R 1000:1000 "${path}" 2>/dev/null || true
    return 0
  fi

  worker_ip="$(kubectl get node "${node}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || true)"
  [[ -n "${worker_ip}" ]] || worker_ip="${node}"

  for target in "${worker_ip}" "${node}"; do
    [[ -n "${target}" ]] || continue
    log "chown via ssh ${target}:${path}"
    if ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        "master@${target}" "sudo chown -R 1000:1000 '${path}'" 2>/dev/null; then
      return 0
    fi
  done

  log "WARN: ssh to worker failed — run ON NODE ${node} (${worker_ip}):"
  log "  sudo chown -R 1000:1000 ${path}"
  return 1
}

wipe_jenkins_pvc() {
  log "scale down + delete Jenkins PVC (jobs re-sync from repo after)"
  if [[ "${JENKINS_SKIP_PVC_BACKUP:-}" != "1" ]] && [[ -x "${SCRIPT_DIR}/lab-jenkins-pvc-backup.sh" ]]; then
    log "snapshot Jenkins home before PVC delete (set JENKINS_SKIP_PVC_BACKUP=1 to skip)"
    bash "${SCRIPT_DIR}/lab-jenkins-pvc-backup.sh" || log "WARN: backup failed — continuing wipe"
  fi
  kubectl scale statefulset/jenkins -n "${JENKINS_NS}" --replicas=0 2>/dev/null || true
  sleep 8
  local pvc
  pvc="$(jenkins_pvc_name)"
  if [[ -n "${pvc}" ]]; then
    kubectl delete pvc -n "${JENKINS_NS}" "${pvc}" --wait=true 2>/dev/null || true
  fi
  kubectl delete pod -n "${JENKINS_NS}" jenkins-0 --force --grace-period=0 2>/dev/null || true
}

diagnose_jenkins_stuck() {
  log "diagnostics:"
  kubectl get pods,pvc,svc -n "${JENKINS_NS}" -o wide 2>/dev/null || true
  helm status "${JENKINS_RELEASE}" -n "${JENKINS_NS}" 2>/dev/null || true
  jenkins_pvc_host_info 2>/dev/null | while IFS='|' read -r pvc pv path node; do
    log "pvc=${pvc} pv=${pv} node=${node} path=${path}"
  done || true
  local pod
  pod="$(kubectl get pods -n "${JENKINS_NS}" -l app.kubernetes.io/component=jenkins-controller \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    kubectl describe pod -n "${JENKINS_NS}" "${pod}" 2>/dev/null | tail -45 || true
    kubectl logs -n "${JENKINS_NS}" "${pod}" -c init --tail=50 2>/dev/null \
      || kubectl logs -n "${JENKINS_NS}" "${pod}" -c init --previous --tail=50 2>/dev/null || true
    kubectl logs -n "${JENKINS_NS}" "${pod}" -c jenkins --tail=40 2>/dev/null || true
  fi
}

ensure_jenkins_nodeport() {
  local actual
  actual="$(kubectl get svc jenkins -n "${JENKINS_NS}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  if [[ -z "${actual}" ]]; then
    log "no jenkins service in ${JENKINS_NS}"
    return 1
  fi
  if [[ "${actual}" == "${JENKINS_NODEPORT}" ]]; then
    log "NodePort already :${JENKINS_NODEPORT}"
    return 0
  fi
  log "fix NodePort ${actual} -> ${JENKINS_NODEPORT} (lab expects :30090)"
  helm upgrade "${JENKINS_RELEASE}" jenkins/jenkins -n "${JENKINS_NS}" \
    --reuse-values \
    --set controller.serviceType=NodePort \
    --set controller.serviceNodePort="${JENKINS_NODEPORT}" \
    --timeout 5m 2>/dev/null || \
  kubectl patch svc jenkins -n "${JENKINS_NS}" --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/ports/0/nodePort\",\"value\":${JENKINS_NODEPORT}}]" 2>/dev/null || true
  actual="$(kubectl get svc jenkins -n "${JENKINS_NS}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  [[ "${actual}" == "${JENKINS_NODEPORT}" ]]
}

node_has_disk_pressure() {
  local node="$1"
  [[ -n "${node}" ]] || return 1
  kubectl describe node "${node}" 2>/dev/null \
    | awk -v n="${node}" '$1=="DiskPressure" && $2=="True" { found=1 } END { exit !found }'
}

pick_jenkins_pin_node() {
  local pin="${JENKINS_PIN_NODE:-}"
  if [[ -z "${pin}" ]]; then
    local info pvc_node
    info="$(jenkins_pvc_host_info 2>/dev/null || true)"
    pvc_node="${info##*|}"
    if [[ -n "${pvc_node}" ]] && ! node_has_disk_pressure "${pvc_node}"; then
      pin="${pvc_node}"
    else
      pin="master"
    fi
  fi
  if node_has_disk_pressure "${pin}"; then
    log "WARN: node ${pin} has DiskPressure — scheduling Jenkins on master instead"
    pin="master"
  fi
  echo "${pin}"
}

helm_jenkins_values() {
  local pin_node
  pin_node="$(pick_jenkins_pin_node)"
  log "Jenkins pin node: ${pin_node}"
  local extra_sets=()
  if [[ "${pin_node}" == "master" ]]; then
    extra_sets+=(
      --set-json 'controller.tolerations=[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"},{"key":"node-role.kubernetes.io/master","operator":"Exists","effect":"NoSchedule"}]'
    )
  fi
  helm upgrade --install "${JENKINS_RELEASE}" jenkins/jenkins -n "${JENKINS_NS}" \
    --set controller.replicaCount=1 \
    --set controller.serviceType=NodePort \
    --set controller.serviceNodePort="${JENKINS_NODEPORT}" \
    --set controller.installPlugins=false \
    --set controller.overwritePluginsFromImage=false \
    --set controller.JCasC.defaultConfig=false \
    --set controller.sidecars.configAutoReload.enabled=false \
    --set controller.runAsUser=1000 \
    --set controller.fsGroup=1000 \
    --set controller.numExecutors="${JENKINS_NUM_EXECUTORS:-4}" \
    --set controller.nodeSelector."kubernetes\.io/hostname"="${pin_node}" \
    --set controller.resources.requests.cpu=250m \
    --set controller.resources.requests.memory=1536Mi \
    --set controller.resources.limits.memory=4Gi \
    --set persistence.enabled=true \
    --set persistence.storageClass=local-path \
    --set persistence.size=8Gi \
    --set agent.enabled=false \
    "${extra_sets[@]}" \
    --timeout 10m
}

repair_jenkins_init() {
  log "repair Init:CrashLoopBackOff (PVC permissions or stale volume)"
  diagnose_jenkins_stuck
  if [[ "${JENKINS_WIPE_PVC:-}" == "1" ]]; then
    wipe_jenkins_pvc
  else
    fix_jenkins_pvc_permissions || true
    kubectl delete pod -n "${JENKINS_NS}" jenkins-0 --force --grace-period=0 2>/dev/null || true
    sleep 20
    if jenkins_init_failing; then
      log "still failing — wiping PVC (set JENKINS_WIPE_PVC=0 to skip auto-wipe)"
      wipe_jenkins_pvc
    fi
  fi
  helm_jenkins_values || log "WARN: helm returned non-zero — continuing"
  kubectl rollout status statefulset/jenkins -n "${JENKINS_NS}" --timeout=1500s 2>/dev/null || true
}

install_jenkins_helm() {
  command -v helm >/dev/null 2>&1 || { log "ERROR: helm required"; return 1; }
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  lab_k8s_api_wait || { log "k3s API not ready"; return 1; }

  if jenkins_http_code | grep -qE '200|403'; then
    log "Jenkins already responding on :${JENKINS_NODEPORT}"
    return 0
  fi

  log "helm repo + namespace ${JENKINS_NS}"
  helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
  helm repo update jenkins
  kubectl create namespace "${JENKINS_NS}" --dry-run=client -o yaml | kubectl apply -f -
  ensure_jenkins_nodeport 2>/dev/null || true

  log "helm upgrade --install (no --wait; installPlugins=false for fast startup)"
  if jenkins_init_failing; then
    repair_jenkins_init
  else
    helm_jenkins_values || log "WARN: helm returned non-zero — continuing to poll pods"
  fi

  log "wait for jenkins-0 pod"
  if kubectl get statefulset jenkins -n "${JENKINS_NS}" >/dev/null 2>&1; then
    kubectl rollout status statefulset/jenkins -n "${JENKINS_NS}" --timeout=1500s 2>/dev/null || true
  fi

  for i in $(seq 1 50); do
    local code ready="no"
    jenkins_pod_ready && ready="yes"
    code="$(jenkins_http_code)"
    log "pod_ready=${ready} http=${code} (${i}/50)"
    [[ "${code}" =~ ^(200|403)$ ]] && break
    if [[ "${i}" -eq 10 || "${i}" -eq 25 ]]; then
      diagnose_jenkins_stuck
      if jenkins_init_failing; then
        repair_jenkins_init
      fi
    fi
    sleep 15
  done

  local final
  final="$(jenkins_http_code)"
  if [[ "${final}" =~ ^(200|403)$ ]]; then
    log "OK — http://${NODE_IP}:${JENKINS_NODEPORT}/login (HTTP ${final})"
    return 0
  fi

  log "ERROR: Jenkins not healthy after install (HTTP ${final})"
  diagnose_jenkins_stuck
  return 1
}

case "${1:-install}" in
  install|helm|recover)
    install_jenkins_helm
    ;;
  repair|fix-init|init)
    repair_jenkins_init
    for i in $(seq 1 40); do
      code="$(jenkins_http_code)"
      log "http=${code} (${i}/40)"
      [[ "${code}" =~ ^(200|403)$ ]] && exit 0
      jenkins_init_failing && [[ "${i}" -eq 20 ]] && repair_jenkins_init
      sleep 15
    done
    diagnose_jenkins_stuck
    exit 1
    ;;
  ensure-nodeport|nodeport)
    ensure_jenkins_nodeport
    ;;
  *)
    echo "usage: lab-jenkins-helm-install.sh [install|repair]" >&2
    exit 1
    ;;
esac
