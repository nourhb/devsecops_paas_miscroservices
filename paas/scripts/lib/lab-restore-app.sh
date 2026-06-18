#!/usr/bin/env bash
# One-shot: Jenkins up + frontend env + pipeline sync (skip DT rebuild).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NODEPORT="${JENKINS_NODEPORT:-30090}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
KTO="${KUBECTL_TIMEOUT:-45s}"

step() { echo ""; echo "========== $* =========="; }

wait_k8s_api() {
  for i in $(seq 1 36); do
    if kubectl get nodes --request-timeout=20s >/dev/null 2>&1; then
      echo "OK: k8s API via kubectl get nodes (attempt ${i})"
      return 0
    fi
    if kubectl get --raw=/healthz --request-timeout=15s >/dev/null 2>&1; then
      echo "OK: k8s API /healthz (attempt ${i})"
      return 0
    fi
    sleep 5
  done
  echo "WARN: k8s API slow — continuing anyway (kubectl may still work with --request-timeout)"
  return 0
}

jenkins_http() {
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 \
    "http://${NODE_IP}:${JENKINS_NODEPORT}/login" 2>/dev/null || echo "000"
}

restart_jenkins() {
  local deploy=""
  deploy="$(kubectl get deploy -n "${JENKINS_NS}" --request-timeout="${KTO}" -o name 2>/dev/null \
    | grep -i jenkins | head -1 || true)"
  if [[ -z "${deploy}" ]]; then
    deploy="$(kubectl get sts -n "${JENKINS_NS}" --request-timeout="${KTO}" -o name 2>/dev/null \
      | grep -i jenkins | head -1 || true)"
  fi
  if [[ -z "${deploy}" ]]; then
    echo "ERROR: no Jenkins Deployment/StatefulSet in ${JENKINS_NS}" >&2
    kubectl get deploy,sts,pods,svc -n "${JENKINS_NS}" --request-timeout="${KTO}" 2>/dev/null || true
    return 1
  fi
  echo "==> Jenkins workload: ${deploy} -n ${JENKINS_NS}"
  kubectl get pods,svc,endpoints -n "${JENKINS_NS}" --request-timeout="${KTO}" 2>/dev/null \
    | grep -i jenkins || true

  kubectl delete pods -n "${JENKINS_NS}" --field-selector=status.phase=Failed \
    --request-timeout="${KTO}" --wait=false 2>/dev/null || true

  echo "==> rollout restart ${deploy}"
  kubectl rollout restart "${deploy}" -n "${JENKINS_NS}" --request-timeout="${KTO}" || true
  if ! kubectl rollout status "${deploy}" -n "${JENKINS_NS}" --timeout=600s --request-timeout="${KTO}"; then
    echo "WARN: rollout status timeout — scale 0 -> 1"
    local kind name
    kind="${deploy%%/*}"
    name="${deploy#*/}"
    kubectl scale "${kind}/${name}" -n "${JENKINS_NS}" --replicas=0 --request-timeout="${KTO}" || true
    sleep 10
    kubectl scale "${kind}/${name}" -n "${JENKINS_NS}" --replicas=1 --request-timeout="${KTO}" || true
    kubectl rollout status "${deploy}" -n "${JENKINS_NS}" --timeout=600s --request-timeout="${KTO}" || true
  fi
}

wait_jenkins_up() {
  local hc
  for i in $(seq 1 60); do
    hc="$(jenkins_http)"
    if [[ "${hc}" =~ ^(200|403)$ ]]; then
      echo "OK: Jenkins NodePort :${JENKINS_NODEPORT} HTTP ${hc} (attempt ${i})"
      return 0
    fi
    echo "waiting Jenkins (${i}/60) HTTP ${hc}"
    sleep 5
  done
  echo "ERROR: Jenkins still down on :${JENKINS_NODEPORT}" >&2
  kubectl get pods,events -n "${JENKINS_NS}" --request-timeout="${KTO}" 2>/dev/null \
    | grep -i jenkins | tail -20 || true
  return 1
}

restart_frontend_env() {
  if ! kubectl get deployment frontend -n "${PAAS_NS}" --request-timeout="${KTO}" >/dev/null 2>&1; then
    echo "WARN: no frontend deployment"
    return 0
  fi
  echo "==> restart frontend to load paas-frontend-env secret"
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}" --request-timeout="${KTO}" 2>/dev/null \
    || kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 \
      --request-timeout="${KTO}" --wait=false 2>/dev/null || true
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s --request-timeout="${KTO}" 2>/dev/null \
    || bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh" || true
}

main() {
  echo "=============================================="
  echo " lab-restore-app — Jenkins + PaaS UI + deploy"
  echo "=============================================="
  df -h / | tail -1

  step "1/6 Kyverno webhooks (unblock patches)"
  PAAS_SKIP_KYVERNO_RESTART=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard || true

  step "2/6 k8s API"
  wait_k8s_api

  step "3/6 Jenkins (${JENKINS_NS})"
  hc="$(jenkins_http)"
  if [[ "${hc}" =~ ^(200|403)$ ]]; then
    echo "OK: Jenkins already up HTTP ${hc}"
  else
    echo "Jenkins HTTP ${hc} — restarting"
    restart_jenkins
    wait_jenkins_up
  fi

  step "4/6 Frontend env (skip Dependency-Track)"
  bash "${SCRIPT_DIR}/compose-paas-frontend-env.sh"
  PAAS_SKIP_DT=1 bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || {
    echo "WARN: env sync had errors — continuing"
  }
  restart_frontend_env

  step "5/6 Jenkins pipeline job (skip DT + skip frontend rebuild)"
  export JENKINS_PROBE_URL="http://${NODE_IP}:${JENKINS_NODEPORT}"
  export JENKINS_LAB_LOOPBACK="http://127.0.0.1:${JENKINS_NODEPORT}"
  SKIP_FRONTEND_REBUILD=true LAB_DT_SKIP_HEAL=true \
    bash "${SCRIPT_DIR}/sync-jenkins-pipeline-from-repo.sh"

  step "6/6 Health"
  bash "${SCRIPT_DIR}/check-paas-lab-health.sh" || true
  hc="$(jenkins_http)"
  echo ""
  echo "=============================================="
  if [[ "${hc}" =~ ^(200|403)$ ]]; then
    echo "OK — try Deploy in UI: http://${NODE_IP}:30100"
    echo "Jenkins UI: http://${NODE_IP}:${JENKINS_NODEPORT}"
  else
    echo "Jenkins still HTTP ${hc} — check: kubectl get pods -n ${JENKINS_NS} | grep -i jenkins"
    echo "  kubectl describe pod -n ${JENKINS_NS} -l app=jenkins | tail -30"
  fi
  echo "=============================================="
}

main "$@"
