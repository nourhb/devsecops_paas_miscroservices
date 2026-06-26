#!/usr/bin/env bash
# kubectl/PATH for non-interactive runs (systemd boot service, cron).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

lab_ensure_kubeconfig() {
  local home="${HOME:-}"
  [[ -n "${home}" ]] || home="/home/master"

  if [[ -n "${KUBECONFIG:-}" && -r "${KUBECONFIG}" ]]; then
    return 0
  fi

  if [[ -r "${home}/.kube/config" ]]; then
    export KUBECONFIG="${home}/.kube/config"
    return 0
  fi

  if [[ -r /etc/rancher/k3s/k3s.yaml ]]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    return 0
  fi

  return 1
}

lab_k8s_api_ready() {
  if command -v k3s >/dev/null 2>&1 && timeout 10 k3s kubectl get --raw=/healthz >/dev/null 2>&1; then
    return 0
  fi
  if timeout 10 kubectl get --raw=/healthz >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Prefer standalone kubectl when kubeconfig exists; else k3s kubectl (common on lab VMs).
if command -v k3s >/dev/null 2>&1; then
  kubectl() {
    if lab_ensure_kubeconfig && command kubectl "$@"; then
      return $?
    fi
    k3s kubectl "$@"
  }
fi

lab_ensure_kubeconfig || true
