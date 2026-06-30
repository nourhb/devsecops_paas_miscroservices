#!/usr/bin/env bash
# Harden Jenkins controller for long paas-deploy steps (Next build, Sonar, crane).
# Build #17 failed Step 5 when jenkins-0 restarted ~58s into Sonar (1536Mi limit + tight probes).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

JENKINS_NS="${JENKINS_NS:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
MEM_LIMIT="${JENKINS_MEM_LIMIT:-4Gi}"
MEM_REQUEST="${JENKINS_MEM_REQUEST:-1536Mi}"

log() { echo "[jenkins-build-safe] $*"; }

if ! kubectl get statefulset jenkins -n "${JENKINS_NS}" >/dev/null 2>&1; then
  echo "FAIL: StatefulSet jenkins not found in ${JENKINS_NS}" >&2
  exit 1
fi

log "patch jenkins StatefulSet: memory limit=${MEM_LIMIT} request=${MEM_REQUEST}; relaxed probes"
kubectl patch statefulset jenkins -n "${JENKINS_NS}" --type='merge' -p "
spec:
  template:
    spec:
      containers:
      - name: jenkins
        resources:
          limits:
            memory: ${MEM_LIMIT}
          requests:
            memory: ${MEM_REQUEST}
        livenessProbe:
          timeoutSeconds: 30
          periodSeconds: 60
          failureThreshold: 10
          initialDelaySeconds: 120
        readinessProbe:
          timeoutSeconds: 30
          periodSeconds: 30
          failureThreshold: 12
          initialDelaySeconds: 30
"

log "rollout jenkins-0 (expect ~1–2 min)"
kubectl rollout status statefulset/jenkins -n "${JENKINS_NS}" --timeout=300s

lim="$(kubectl get pod -n "${JENKINS_NS}" "${JPOD}" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
log "jenkins-0 memory limit=${lim:-unknown}"
log "optional JENKINS-48300: add to controller JAVA_OPTS:"
log "  -Dorg.jenkinsci.plugins.durabletask.BourneShellScript.HEARTBEAT_CHECK_INTERVAL=300"
log "done — sync pipeline + deploy:"
log "  bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh"
