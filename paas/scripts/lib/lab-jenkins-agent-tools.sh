#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"
JENKINS_NS="${JENKINS_NS:-cicd}"
# shellcheck source=lab-jenkins-pod.sh
source "${SCRIPT_DIR}/lab-jenkins-pod.sh"
HELM_VERSION="${JENKINS_PAAS_HELM_VERSION:-3.16.3}"
CRANE_VERSION="${JENKINS_PAAS_CRANE_VERSION:-0.20.6}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }

jenkins_pod_sh() {
  jenkins_exec "${JENKINS_NS}" sh -s
}

ensure_helm_on_jenkins() {
  jenkins_pod_sh <<EOF
set -eu
HELM_VERSION="${HELM_VERSION}"
HELM_BIN="\${JENKINS_HOME:-/var/jenkins_home}/.jenkins-paas-cache/helm/helm-v\${HELM_VERSION}/helm"
if [ -x "\${HELM_BIN}" ]; then
  echo "OK: helm already installed: \${HELM_BIN}"
  "\${HELM_BIN}" version --short 2>/dev/null || true
  exit 0
fi
mkdir -p "\$(dirname "\${HELM_BIN}")"
TDIR="\$(mktemp -d)"
curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 \\
  "https://get.helm.sh/helm-v\${HELM_VERSION}-linux-amd64.tar.gz" \\
  -o "\${TDIR}/helm.tar.gz"
tar -xzf "\${TDIR}/helm.tar.gz" -C "\${TDIR}" linux-amd64/helm
mv "\${TDIR}/linux-amd64/helm" "\${HELM_BIN}"
chmod +x "\${HELM_BIN}"
rm -rf "\${TDIR}"
echo "OK: installed \${HELM_BIN}"
"\${HELM_BIN}" version --short
EOF
}

ensure_crane_on_jenkins() {
  jenkins_pod_sh <<EOF
set -eu
CRANE_VERSION="${CRANE_VERSION}"
CRANE_BIN="\${JENKINS_HOME:-/var/jenkins_home}/.jenkins-paas-cache/crane/crane-v\${CRANE_VERSION}/crane"
if [ -x "\${CRANE_BIN}" ]; then
  echo "OK: crane already installed: \${CRANE_BIN}"
  exit 0
fi
mkdir -p "\$(dirname "\${CRANE_BIN}")"
TDIR="\$(mktemp -d)"
curl -fsSL --retry 3 --connect-timeout 20 --max-time 300 \\
  "https://github.com/google/go-containerregistry/releases/download/v\${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \\
  -o "\${TDIR}/crane.tar.gz"
tar -xzf "\${TDIR}/crane.tar.gz" -C "\${TDIR}" crane
mv "\${TDIR}/crane" "\${CRANE_BIN}"
chmod +x "\${CRANE_BIN}"
rm -rf "\${TDIR}"
echo "OK: installed \${CRANE_BIN}"
EOF
}

main() {
  echo "==> Jenkins agent tools (helm + crane cache under JENKINS_HOME)"
  if ! lab_k8s_api_ready; then
    warn "Kubernetes API not reachable — restart k3s: sudo systemctl restart k3s"
    warn "Then: bash paas/scripts/lab.sh start"
    exit 1
  fi
  if [[ -z "$(jenkins_pod_name "${JENKINS_NS}")" ]]; then
    warn "Jenkins pod not found in ${JENKINS_NS} (is Jenkins deployed?)"
    kubectl get deploy,sts,pods -n "${JENKINS_NS}" --request-timeout=30s 2>/dev/null || true
    exit 1
  fi
  ensure_crane_on_jenkins || warn "crane pre-install skipped"
  ensure_helm_on_jenkins || warn "helm pre-install skipped"
  ok "Jenkins agent tools ready (pipeline also auto-installs on first build)"
}

main "$@"
