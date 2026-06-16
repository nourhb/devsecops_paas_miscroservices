#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
KEY_PATH="/var/jenkins_home/cosign-lab/cosign.key"

jenkins_pod() {
  kubectl get pods -n "${JENKINS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | grep -v Terminating | head -1 || true
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "WARN: ${ENV_FILE} missing — skip COSIGN_PUBLIC_KEY sync" >&2
  exit 0
fi

pod="$(jenkins_pod)"
if [[ -z "${pod}" ]]; then
  echo "WARN: no Jenkins pod in ${JENKINS_NS} — skip COSIGN_PUBLIC_KEY sync" >&2
  exit 0
fi

if ! kubectl exec -n "${JENKINS_NS}" "${pod}" -- test -f "${KEY_PATH}" 2>/dev/null; then
  echo "WARN: ${KEY_PATH} not found in ${JENKINS_NS}/${pod}" >&2
  exit 0
fi

pub="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- cosign public-key --key "${KEY_PATH}" 2>/dev/null || true)"
if [[ -z "${pub}" ]]; then
  echo "WARN: cosign public-key failed in ${JENKINS_NS}/${pod}" >&2
  exit 0
fi

escaped="$(printf '%s' "${pub}" | awk 'NF{printf "%s\\n",$0}')"
tmp="$(mktemp)"
trap 'rm -f "${tmp}"' EXIT
if grep -q '^COSIGN_PUBLIC_KEY=' "${ENV_FILE}"; then
  sed "s|^COSIGN_PUBLIC_KEY=.*|COSIGN_PUBLIC_KEY=\"${escaped}\"|" "${ENV_FILE}" > "${tmp}"
else
  cat "${ENV_FILE}" > "${tmp}"
  printf '\nCOSIGN_PUBLIC_KEY="%s"\n' "${escaped}" >> "${tmp}"
fi
mv "${tmp}" "${ENV_FILE}"
trap - EXIT
echo "OK: COSIGN_PUBLIC_KEY synced from ${JENKINS_NS}/${pod} into ${ENV_FILE}"
