#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
REMOTE="${JENKINS_STAGES_REMOTE_PATH:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
DT_MARKER="${DT_STAGES_MARKER:-dt-api-server-svc-20260617}"
GENERATED="$(mktemp)"
trap 'rm -f "${GENERATED}"' EXIT

discover_jenkins_pods() {
  local ns pod
  for ns in ${JENKINS_K8S_NAMESPACE:-} cicd jenkins devsecops; do
    [[ -n "${ns}" ]] || continue
    kubectl get ns "${ns}" >/dev/null 2>&1 || continue
    while IFS= read -r pod; do
      [[ -n "${pod}" ]] || continue
      printf '%s %s\n' "${ns}" "${pod}"
    done < <(
      kubectl get pods -n "${ns}" --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -iE 'jenkins' | grep -v Terminating || true
    )
  done | awk '!seen[$1" "$2]++'
}

jenkins_running_pod() {
  discover_jenkins_pods | head -1 | awk '{print $2}'
}

jenkins_running_namespace() {
  discover_jenkins_pods | head -1 | awk '{print $1}'
}

verify_remote_stages() {
  local ns="$1" pod="$2"
  kubectl exec -n "${ns}" "${pod}" -- grep -qF "${DT_MARKER}" "${REMOTE}" 2>/dev/null \
    && kubectl exec -n "${ns}" "${pod}" -- grep -qF 'def runPaasStep12' "${REMOTE}" 2>/dev/null
}

install_to_pod() {
  local ns="$1" pod="$2"
  local container="${JENKINS_CONTAINER:-jenkins}"
  kubectl exec -n "${ns}" "${pod}" -c "${container}" -- mkdir -p /var/jenkins_home/paas 2>/dev/null \
    || kubectl exec -n "${ns}" "${pod}" -- mkdir -p /var/jenkins_home/paas
  kubectl cp "${GENERATED}" "${ns}/${pod}:${REMOTE}" -c "${container}" 2>/dev/null \
    || kubectl cp "${GENERATED}" "${ns}/${pod}:${REMOTE}"
  verify_remote_stages "${ns}" "${pod}"
}

python3 "${REPO_ROOT}/paas/jenkins/render-loadable-stages.py" > "${GENERATED}" || {
  echo "ERROR: render-loadable-stages.py failed (see message above)" >&2
  exit 1
}
if ! grep -qF 'def coerceHarborHostForCosign' "${GENERATED}"; then
  echo "ERROR: generated stages file missing helpers (coerceHarborHostForCosign)" >&2
  exit 1
fi
if ! grep -qF 'def runPaasStep12' "${GENERATED}"; then
  echo "ERROR: generated stages file missing runPaasStep12" >&2
  exit 1
fi
if ! grep -qF 'paas-blueocean-12steps-20260618' "${GENERATED}"; then
  echo "ERROR: generated stages file missing Blue Ocean 12-step bundle marker" >&2
  exit 1
fi
if ! grep -qF 'dt_upload_candidates' "${GENERATED}"; then
  echo "ERROR: generated stages still has legacy pick_dt_base — update Jenkinsfile.paas-deploy" >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "WARN: kubectl missing — trying local /var/jenkins_home"
else
  mapfile -t _pods < <(discover_jenkins_pods)
  if [[ ${#_pods[@]} -gt 0 ]]; then
    INSTALLED=0
    for line in "${_pods[@]}"; do
      ns="${line%% *}"
      pod="${line#* }"
      [[ -n "${ns}" && -n "${pod}" ]] || continue
      echo "==> Installing stages to ${ns}/${pod}:${REMOTE}"
      if install_to_pod "${ns}" "${pod}"; then
        echo "OK: ${REMOTE} on ${ns}/${pod} (${DT_MARKER})"
        INSTALLED=1
      else
        echo "WARN: install/verify failed for ${ns}/${pod}" >&2
      fi
    done
    if [[ "${INSTALLED}" -eq 1 ]]; then
      exit 0
    fi
    echo "ERROR: found Jenkins pod(s) but could not install verified stages file" >&2
    exit 1
  fi
  echo "WARN: no Running Jenkins pod in cicd/jenkins — tried: $(discover_jenkins_pods | tr '\n' ' ')"
fi

if [[ -d /var/jenkins_home ]]; then
  sudo mkdir -p /var/jenkins_home/paas
  sudo cp "${GENERATED}" "${REMOTE}"
  sudo chmod 644 "${REMOTE}" 2>/dev/null || true
  if ! grep -qF "${DT_MARKER}" "${REMOTE}" 2>/dev/null; then
    echo "ERROR: ${REMOTE} missing ${DT_MARKER} after copy" >&2
    exit 1
  fi
  echo "OK: ${REMOTE} on Jenkins host (${DT_MARKER})"
  exit 0
fi

echo "ERROR: could not install stages file (no Running Jenkins pod and no /var/jenkins_home)" >&2
echo "  Fix: kubectl get pods -A | grep -i jenkins" >&2
exit 1
