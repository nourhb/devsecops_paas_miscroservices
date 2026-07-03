#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"
JENKINS_NS="${JENKINS_NS:-cicd}"
ZAP_NS="${ZAP_K8S_NAMESPACE:-cicd}"
KUBECTL_VERSION="${JENKINS_KUBECTL_VERSION:-1.31.4}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }

jenkins_exec() {
  local target="${JENKINS_POD:-}"
  if [[ -z "${target}" ]]; then
    if kubectl get pod -n "${JENKINS_NS}" jenkins-0 >/dev/null 2>&1; then
      target="pod/jenkins-0"
    else
      target="deploy/jenkins"
    fi
  fi
  kubectl exec -n "${JENKINS_NS}" "${target}" --request-timeout=120s -- "$@"
}

ensure_kubectl_in_jenkins() {
  local kbin_path="/var/jenkins_home/bin/kubectl"
  local target="${JENKINS_POD:-}"

  if jenkins_exec sh -c "test -x '${kbin_path}' && '${kbin_path}' version --client >/dev/null 2>&1"; then
    ok "kubectl already installed and working in Jenkins pod: ${kbin_path}"
    return 0
  fi

  jenkins_exec sh -c "mkdir -p \"\$(dirname '${kbin_path}')\"; rm -f '${kbin_path}'" 2>/dev/null || true

  if [[ -z "${target}" ]]; then
    if kubectl get pod -n "${JENKINS_NS}" jenkins-0 >/dev/null 2>&1; then
      target="jenkins-0"
    else
      target="$(kubectl get pod -n "${JENKINS_NS}" -l app.kubernetes.io/component=jenkins-controller -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      [[ -n "${target}" ]] || target="$(kubectl get pod -n "${JENKINS_NS}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    fi
  else
    target="${target#pod/}"
  fi

  local local_kubectl="" candidate resolved
  for candidate in "$(command -v kubectl 2>/dev/null || true)" /usr/local/bin/kubectl /usr/bin/kubectl /var/lib/rancher/k3s/data/current/bin/kubectl; do
    [[ -n "${candidate}" ]] || continue
    resolved="$(readlink -f "${candidate}" 2>/dev/null || echo "${candidate}")"
    [[ -f "${resolved}" ]] || continue
    local_kubectl="${resolved}"
    break
  done
  if [[ -z "${local_kubectl}" ]] && command -v k3s >/dev/null 2>&1; then
    local_kubectl="$(readlink -f "$(command -v k3s)" 2>/dev/null || command -v k3s)"
  fi

  if [[ -n "${local_kubectl}" && -n "${target}" ]]; then
    echo "==> copying local kubectl (${local_kubectl}) into pod/${target} via kubectl cp (no pod egress needed)"
    if kubectl cp "${local_kubectl}" "${JENKINS_NS}/${target}:${kbin_path}" -c jenkins 2>/dev/null \
      || kubectl cp "${local_kubectl}" "${JENKINS_NS}/${target}:${kbin_path}" 2>/dev/null; then
      jenkins_exec sh -c "chmod +x '${kbin_path}'" 2>/dev/null || true
      if jenkins_exec sh -c "'${kbin_path}' version --client >/dev/null 2>&1"; then
        ok "kubectl installed via kubectl cp: ${kbin_path}"
        return 0
      fi
      warn "copied kubectl but it does not run in the pod — falling back to curl download"
    else
      warn "kubectl cp failed — falling back to curl download inside pod"
    fi
  else
    warn "no local kubectl/k3s binary resolvable on host — falling back to curl download inside pod"
  fi

  jenkins_exec sh -s <<EOF
set -eu
KVER="${KUBECTL_VERSION}"
KBIN="${kbin_path}"
mkdir -p "\$(dirname "\${KBIN}")"
rm -f "\${KBIN}"
for url in \
  "https://dl.k8s.io/release/v\${KVER}/bin/linux/amd64/kubectl" \
  "https://storage.googleapis.com/kubernetes-release/release/v\${KVER}/bin/linux/amd64/kubectl"; do
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 "\${url}" -o "\${KBIN}" && [ -s "\${KBIN}" ] && break
  elif command -v wget >/dev/null 2>&1; then
    wget -q --timeout=300 "\${url}" -O "\${KBIN}" && [ -s "\${KBIN}" ] && break
  fi
done
if [ ! -s "\${KBIN}" ]; then
  echo "FAIL: kubectl download failed (no pod egress to dl.k8s.io and no local binary to cp)" >&2
  exit 1
fi
chmod +x "\${KBIN}"
echo "OK: installed \${KBIN}"
"\${KBIN}" version --client --short 2>/dev/null || "\${KBIN}" version --client
EOF
}

ensure_zap_rbac() {
  kubectl apply -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins
  namespace: ${JENKINS_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-zap-runner
  namespace: ${ZAP_NS}
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log", "pods/exec"]
    verbs: ["create", "delete", "get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-zap-runner
  namespace: ${ZAP_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-zap-runner
subjects:
  - kind: ServiceAccount
    name: jenkins
    namespace: ${JENKINS_NS}
  - kind: ServiceAccount
    name: default
    namespace: ${JENKINS_NS}
YAML
  ok "RBAC jenkins → ${ZAP_NS} pods (ZAP baseline)"
}

ensure_dt_rbac() {
  kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: jenkins-dt-portforward
  namespace: dependency-track
rules:
  - apiGroups: [""]
    resources: ["services", "pods"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["pods/portforward"]
    verbs: ["create"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: jenkins-dt-portforward
  namespace: dependency-track
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: jenkins-dt-portforward
subjects:
  - kind: ServiceAccount
    name: default
    namespace: ${JENKINS_NS}
  - kind: ServiceAccount
    name: jenkins
    namespace: ${JENKINS_NS}
YAML
  ok "RBAC jenkins → dependency-track port-forward (Step 4 SBOM upload fallback)"
}

ensure_ram_pause_rbac() {
  kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-lab-ram-pause
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "deployments/scale"]
    verbs: ["get", "list", "watch", "patch", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: jenkins-lab-ram-pause
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: jenkins-lab-ram-pause
subjects:
  - kind: ServiceAccount
    name: default
    namespace: ${JENKINS_NS}
  - kind: ServiceAccount
    name: jenkins
    namespace: ${JENKINS_NS}
YAML
  ok "RBAC jenkins → scale deployments cluster-wide (RAM pause during Sonar)"
}

jenkins_workload_present() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if kubectl get pod -n "${JENKINS_NS}" jenkins-0 --request-timeout=30s >/dev/null 2>&1; then
      return 0
    fi
    if kubectl get deploy/jenkins -n "${JENKINS_NS}" --request-timeout=30s >/dev/null 2>&1; then
      return 0
    fi
    if kubectl get pod -n "${JENKINS_NS}" -l app.kubernetes.io/component=jenkins-controller \
      --request-timeout=30s -o name 2>/dev/null | grep -q .; then
      return 0
    fi
    warn "Jenkins pod/deploy lookup attempt ${attempt}/5 failed (k3s API busy?) — retrying in 5s"
    sleep 5
  done
  return 1
}

main() {
  echo "==> Jenkins ZAP tools (kubectl in pod + RBAC)"
  if ! lab_k8s_api_ready; then
    warn "Kubernetes API not reachable — restart k3s first"
    exit 1
  fi
  if ! jenkins_workload_present; then
    warn "no Jenkins pod/deployment found in ns=${JENKINS_NS} after retries — continuing anyway (ensure_kubectl_in_jenkins does its own pod resolution)"
  fi
  ensure_kubectl_in_jenkins
  ensure_zap_rbac
  ensure_dt_rbac
  ensure_ram_pause_rbac
  ok "Jenkins can run ZAP via kubectl run in ${ZAP_NS}"
}

main "$@"
