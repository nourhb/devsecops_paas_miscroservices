#!/usr/bin/env bash
# systemd ExecStart wrapper — kubeconfig + k3s kubectl before lab.sh start
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

lab_install_kubeconfig() {
  local home="${HOME:-/home/master}"
  local dest="${home}/.kube/config"
  [[ -r "${dest}" ]] && return 0
  [[ -f /etc/rancher/k3s/k3s.yaml ]] || return 1
  mkdir -p "${home}/.kube"
  if cp /etc/rancher/k3s/k3s.yaml "${dest}" 2>/dev/null; then
    chmod 600 "${dest}" 2>/dev/null || true
  elif command -v k3s >/dev/null 2>&1; then
    k3s kubectl config view --raw > "${dest}" 2>/dev/null || return 1
    chmod 600 "${dest}" 2>/dev/null || true
  else
    return 1
  fi
  export KUBECONFIG="${dest}"
}

lab_install_kubeconfig || true
lab_ensure_kubeconfig || true

exec /bin/bash "${REPO_ROOT}/paas/scripts/lab.sh" start
