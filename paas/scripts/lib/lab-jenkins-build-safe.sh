#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

log "patch jenkins StatefulSet: memory limit=${MEM_LIMIT} request=${MEM_REQUEST}; relaxed probes (json patch)"
kubectl patch statefulset jenkins -n "${JENKINS_NS}" --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${MEM_LIMIT}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/requests/memory\",\"value\":\"${MEM_REQUEST}\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/timeoutSeconds\",\"value\":30},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/periodSeconds\",\"value\":60},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/failureThreshold\",\"value\":10},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds\",\"value\":120},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds\",\"value\":30},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/periodSeconds\",\"value\":30},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/failureThreshold\",\"value\":12},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds\",\"value\":30}
]"

log "rollout jenkins-0 (expect ~1–2 min)"
kubectl rollout status statefulset/jenkins -n "${JENKINS_NS}" --timeout=300s

lim="$(kubectl get pod -n "${JENKINS_NS}" "${JPOD}" -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null || true)"
log "jenkins-0 memory limit=${lim:-unknown}"
log "done"
