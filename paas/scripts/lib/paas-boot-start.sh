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
  [[ -r "${dest}" ]] && { export KUBECONFIG="${dest}"; return 0; }
  mkdir -p "${home}/.kube"
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    if cp /etc/rancher/k3s/k3s.yaml "${dest}" 2>/dev/null; then
      chmod 600 "${dest}" 2>/dev/null || true
    elif command -v k3s >/dev/null 2>&1; then
      k3s kubectl config view --raw > "${dest}" 2>/dev/null || return 1
      chmod 600 "${dest}" 2>/dev/null || true
    else
      return 1
    fi
    export KUBECONFIG="${dest}"
    return 0
  fi
  if command -v k3s >/dev/null 2>&1; then
    k3s kubectl config view --raw > "${dest}" 2>/dev/null || return 1
    chmod 600 "${dest}" 2>/dev/null || true
    export KUBECONFIG="${dest}"
    return 0
  fi
  return 1
}

lab_install_kubeconfig || true
lab_ensure_kubeconfig || true

bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" || exit 1

# Cold VM boot: k3s unit may be up before API accepts requests.
for i in $(seq 1 24); do
  if lab_k8s_api_ready; then
    break
  fi
  sleep 5
done

exec /bin/bash "${REPO_ROOT}/paas/scripts/lab.sh" start
