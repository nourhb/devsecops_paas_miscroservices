#!/usr/bin/env bash
# One-shot Harbor push fix for lab VM (project RBAC + robot + env + Jenkins params + crane probe).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "${REPO_ROOT}"

echo "=============================================="
echo " FIX Harbor push (RBAC + robot + sync)"
echo "=============================================="

python3 "${SCRIPT_DIR}/harbor-push-rbac-fix.py"

# Reload creds written by harbor-push-rbac-fix.py
set -a
# shellcheck disable=SC1091
source "${REPO_ROOT}/paas/frontend/docker-compose.env" 2>/dev/null || true
set +a
HARBOR_USER="${HARBOR_USERNAME:-admin}"
HARBOR_PASS="${HARBOR_PASSWORD:-Harbor12345}"
export HARBOR_USER HARBOR_PASS HARBOR_CREDS_FROM_SECRET=1

echo "==> crane push probe from jenkins-0"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="$(kubectl get pods -n "${JENKINS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i jenkins | grep -v Terminating | head -1 || true)"
if [[ -z "${JPOD}" ]]; then
  echo "WARN: jenkins pod not found — skip crane probe"
else
  kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c jenkins --request-timeout=180s -- bash -s <<EOS
set -eu
CRANE=""
for c in /var/jenkins_home/.jenkins-paas-cache/crane/*/crane /var/jenkins_home/bin/crane; do
  [ -x "\$c" ] && CRANE="\$c" && break
done
[ -n "\$CRANE" ] || { echo "ERROR: crane missing on jenkins pod"; exit 1; }
export DOCKER_CONFIG="/tmp/paas-harbor-probe-\$\$"
mkdir -p "\$DOCKER_CONFIG"
trap 'rm -rf "\$DOCKER_CONFIG"' EXIT
printf '%s' "${HARBOR_PASS}" | "\$CRANE" auth login "${NODE_IP}:${HARBOR_NODEPORT}" -u "${HARBOR_USER}" --password-stdin --insecure
printf '%s' "${HARBOR_PASS}" | "\$CRANE" auth login "harbor.${NODE_IP}.nip.io:${HARBOR_NODEPORT}" -u "${HARBOR_USER}" --password-stdin --insecure || true
"\$CRANE" pull --insecure mirror.gcr.io/library/alpine:3.20 /tmp/paas-probe.tar
TAG="probe-\$(date +%s)"
"\$CRANE" push --insecure /tmp/paas-probe.tar "${NODE_IP}:${HARBOR_NODEPORT}/${HARBOR_PROJECT:-paas}/paas-harbor-push-probe:\${TAG}"
"\$CRANE" digest --insecure "${NODE_IP}:${HARBOR_NODEPORT}/${HARBOR_PROJECT:-paas}/paas-harbor-push-probe:\${TAG}"
rm -f /tmp/paas-probe.tar
echo "OK: crane push probe ${NODE_IP}:${HARBOR_NODEPORT}/${HARBOR_PROJECT:-paas}/paas-harbor-push-probe:\${TAG}"
EOS
fi

echo ""
echo "=============================================="
echo " DONE — next on this VM:"
echo "   bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh"
echo "   bash paas/scripts/lab.sh env-quick"
echo "   trigger NEW paas-deploy from PaaS UI (NOT Replay)"
echo "=============================================="
