#!/usr/bin/env bash
# Lab script to pvc retain on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"

RETAIN_ANNOTATIONS='{"helm.sh/resource-policy":"keep","paas.lab/retain":"true"}'
RETAIN_LABEL='{"paas.lab/data-retain":"true"}'

log() { echo "[pvc-retain] $*"; }

kubectl_try() {
  k3s kubectl "$@" --request-timeout=45s 2>/dev/null \
    || kubectl "$@" --request-timeout=45s 2>/dev/null \
    || return 1
}

annotate_pvc() {
  local ns="$1" pvc="$2"
  kubectl_try get pvc -n "${ns}" "${pvc}" >/dev/null 2>&1 || return 0
  kubectl_try annotate pvc -n "${ns}" "${pvc}" \
    helm.sh/resource-policy=keep paas.lab/retain=true --overwrite 2>/dev/null || true
  kubectl_try label pvc -n "${ns}" "${pvc}" paas.lab/data-retain=true --overwrite 2>/dev/null || true
  log "retain: ${ns}/${pvc}"
}

guard_all() {
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  annotate_pvc paas postgres-pvc
  for ns in paas cicd sonarqube dependency-track harbor artifactory monitoring; do
    kubectl_try get ns "${ns}" >/dev/null 2>&1 || continue
    while read -r pvc; do
      [[ -n "${pvc}" ]] || continue
      annotate_pvc "${ns}" "${pvc}"
    done < <(kubectl_try get pvc -n "${ns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  done
  log "OK: retain annotations applied"
}

status_all() {
  lab_sync_kubeconfig 2>/dev/null || lab_ensure_kubeconfig || true
  echo "==> Lab PVCs (data survives pod restart when Bound)"
  for ns in paas cicd sonarqube dependency-track harbor artifactory monitoring; do
    kubectl_try get ns "${ns}" >/dev/null 2>&1 || continue
    kubectl_try get pvc -n "${ns}" -o custom-columns=\
'NS:.metadata.namespace,NAME:.metadata.name,SIZE:.spec.resources.requests.storage,STATUS:.status.phase,RETAIN:.metadata.annotations.paas\.lab/retain' \
      2>/dev/null | tail -n +2 | while read -r line; do
      [[ -n "${line}" ]] && echo "  ${line}"
    done || true
  done
  echo ""
  echo "==> Ephemeral risk check"
  if kubectl_try get pod -n sonarqube -l app=sonarqube -o yaml 2>/dev/null | grep -q 'emptyDir: {}'; then
    echo "  WARN: SonarQube still uses emptyDir"
  else
    echo "  OK: SonarQube pod uses PVC (or not installed)"
  fi
}

cmd="${1:-guard}"
case "${cmd}" in
  guard|apply) guard_all ;;
  status|list) status_all ;;
  *)
    echo "usage: lab-pvc-retain.sh {guard|status}" >&2
    exit 1
    ;;
esac
