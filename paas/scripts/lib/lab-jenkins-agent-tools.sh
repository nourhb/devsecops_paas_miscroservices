#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JENKINS_NS="${JENKINS_NS:-cicd}"
HELM_VERSION="${JENKINS_PAAS_HELM_VERSION:-3.16.3}"
CRANE_VERSION="${JENKINS_PAAS_CRANE_VERSION:-0.20.6}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*"; }

jenkins_exec() {
  kubectl exec -n "${JENKINS_NS}" deploy/jenkins --request-timeout=120s -- "$@"
}

ensure_helm_on_jenkins() {
  jenkins_exec sh -s <<EOF
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
  jenkins_exec sh -s <<EOF
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
tar -xzf "\${TDIR}/crane.tar.gz" -C "\$(dirname "\${CRANE_BIN}")" crane
mv "\$(dirname "\${CRANE_BIN}")/crane" "\${CRANE_BIN}"
chmod +x "\${CRANE_BIN}"
rm -rf "\${TDIR}"
echo "OK: installed \${CRANE_BIN}"
EOF
}

main() {
  echo "==> Jenkins agent tools (helm + crane cache under JENKINS_HOME)"
  if ! kubectl get deploy/jenkins -n "${JENKINS_NS}" >/dev/null 2>&1; then
    warn "deploy/jenkins not found in ${JENKINS_NS}"
    exit 1
  fi
  ensure_crane_on_jenkins || warn "crane pre-install skipped"
  ensure_helm_on_jenkins || warn "helm pre-install skipped"
  ok "Jenkins agent tools ready (pipeline also auto-installs on first build)"
}

main "$@"
