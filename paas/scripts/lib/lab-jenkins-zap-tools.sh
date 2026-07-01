#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
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
  jenkins_exec sh -s <<EOF
set -eu
KVER="${KUBECTL_VERSION}"
KBIN="\${JENKINS_HOME:-/var/jenkins_home}/bin/kubectl"
mkdir -p "\$(dirname "\${KBIN}")"
if [ -x "\${KBIN}" ]; then
  echo "OK: kubectl already installed: \${KBIN}"
  "\${KBIN}" version --client --short 2>/dev/null || "\${KBIN}" version --client
  exit 0
fi
curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 \\
  "https://dl.k8s.io/release/v\${KVER}/bin/linux/amd64/kubectl" \\
  -o "\${KBIN}"
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

main() {
  echo "==> Jenkins ZAP tools (kubectl in pod + RBAC)"
  if ! lab_k8s_api_ready; then
    warn "Kubernetes API not reachable — restart k3s first"
    exit 1
  fi
  kubectl get pod/jenkins-0 -n "${JENKINS_NS}" --request-timeout=30s >/dev/null 2>&1 \
    || kubectl get deploy/jenkins -n "${JENKINS_NS}" --request-timeout=30s >/dev/null
  ensure_kubectl_in_jenkins
  ensure_zap_rbac
  ok "Jenkins can run ZAP via kubectl run in ${ZAP_NS}"
}

main "$@"
