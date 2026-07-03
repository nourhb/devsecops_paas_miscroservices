#!/usr/bin/env bash
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"

jenkins_discover_ns() {
  local ns
  for ns in ${JENKINS_K8S_NAMESPACE:-} cicd jenkins devsecops; do
    [[ -n "${ns}" ]] || continue
    kubectl get ns "${ns}" --request-timeout=20s >/dev/null 2>&1 || continue
    if kubectl get statefulset jenkins -n "${ns}" --request-timeout=20s >/dev/null 2>&1; then
      echo "${ns}"
      return 0
    fi
    if kubectl get deploy jenkins -n "${ns}" --request-timeout=20s >/dev/null 2>&1; then
      echo "${ns}"
      return 0
    fi
    if kubectl get pods -n "${ns}" -l app.kubernetes.io/component=jenkins-controller \
      --request-timeout=20s -o name 2>/dev/null | grep -q .; then
      echo "${ns}"
      return 0
    fi
  done
  return 1
}

jenkins_pod_name() {
  local ns="${1:-${JENKINS_K8S_NAMESPACE:-cicd}}"
  local pod
  pod="$(kubectl get pods -n "${ns}" -l app.kubernetes.io/component=jenkins-controller \
    -o jsonpath='{.items[0].metadata.name}' --request-timeout=20s 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    echo "${pod}"
    return 0
  fi
  pod="$(kubectl get pods -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    --request-timeout=20s 2>/dev/null | grep -iE '^jenkins' | head -1 || true)"
  [[ -n "${pod}" ]] && echo "${pod}"
}

jenkins_workload_ref() {
  local ns="${1:-${JENKINS_K8S_NAMESPACE:-cicd}}"
  if kubectl get statefulset jenkins -n "${ns}" --request-timeout=20s >/dev/null 2>&1; then
    echo "statefulset/jenkins"
    return 0
  fi
  if kubectl get deploy jenkins -n "${ns}" --request-timeout=20s >/dev/null 2>&1; then
    echo "deployment/jenkins"
    return 0
  fi
  return 1
}

jenkins_exec() {
  local ns="${1:-}"
  shift || true
  local pod kto="${KUBECTL_REQUEST_TIMEOUT:-120s}"
  [[ -n "${ns}" ]] || ns="$(jenkins_discover_ns)" || return 1
  pod="$(jenkins_pod_name "${ns}")"
  [[ -n "${pod}" ]] || return 1
  kubectl exec -n "${ns}" "${pod}" -c "${JENKINS_CONTAINER}" --request-timeout="${kto}" -- "$@"
}

jenkins_exec_i() {
  local ns="${1:-}"
  shift || true
  local pod kto="${KUBECTL_REQUEST_TIMEOUT:-120s}"
  [[ -n "${ns}" ]] || ns="$(jenkins_discover_ns)" || return 1
  pod="$(jenkins_pod_name "${ns}")"
  [[ -n "${pod}" ]] || return 1
  kubectl exec -i -n "${ns}" "${pod}" -c "${JENKINS_CONTAINER}" --request-timeout="${kto}" -- "$@"
}

jenkins_print_exec_hint() {
  local ns="${1:-${JENKINS_K8S_NAMESPACE:-cicd}}"
  local pod
  pod="$(jenkins_pod_name "${ns}" 2>/dev/null || echo jenkins-0)"
  echo "  kubectl exec -i -n ${ns} ${pod} -c ${JENKINS_CONTAINER} --"
}
