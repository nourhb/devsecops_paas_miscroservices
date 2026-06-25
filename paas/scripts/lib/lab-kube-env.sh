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

lab_ensure_kubeconfig || true
