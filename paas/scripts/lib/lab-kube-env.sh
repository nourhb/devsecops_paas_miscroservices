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

  # Never export root-only /etc/rancher/k3s/k3s.yaml — copy to ~/.kube/config instead.
  if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
    lab_sync_kubeconfig && return 0
  fi

  unset KUBECONFIG 2>/dev/null || true
  return 1
}

# Refresh ~/.kube/config from k3s on every VM boot (certs/paths may change).
lab_sync_kubeconfig() {
  local home="${HOME:-}"
  [[ -n "${home}" ]] || home="/home/master"
  local dest="${home}/.kube/config"
  mkdir -p "${home}/.kube"
  if [[ ! -r /etc/rancher/k3s/k3s.yaml ]]; then
    lab_ensure_kubeconfig || return 1
    return 0
  fi
  if cp -f /etc/rancher/k3s/k3s.yaml "${dest}" 2>/dev/null; then
    chmod 600 "${dest}" 2>/dev/null || true
  elif command -v sudo >/dev/null 2>&1; then
    sudo install -d -o "${USER}" -g "${USER}" -m 700 "${home}/.kube" 2>/dev/null || true
    sudo install -o "${USER}" -g "${USER}" -m 600 /etc/rancher/k3s/k3s.yaml "${dest}" 2>/dev/null || return 1
  else
    return 1
  fi
  export KUBECONFIG="${dest}"
  return 0
}

lab_k8s_api_probe() {
  local req="${1:---request-timeout=${LAB_K8S_API_TIMEOUT_SEC:-8}s}"
  local to="${LAB_K8S_PROBE_TIMEOUT_SEC:-12}"
  if command -v k3s >/dev/null 2>&1; then
    if timeout "${to}" k3s kubectl get --raw=/healthz "${req}" >/dev/null 2>&1; then
      return 0
    fi
    if timeout "${to}" k3s kubectl get nodes "${req}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  lab_ensure_kubeconfig || true
  if timeout "${to}" kubectl get --raw=/healthz "${req}" >/dev/null 2>&1; then
    return 0
  fi
  if timeout "${to}" kubectl get nodes "${req}" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

lab_k8s_api_ready() {
  local retries="${LAB_K8S_API_RETRIES:-3}"
  local i
  for i in $(seq 1 "${retries}"); do
    if lab_k8s_api_probe; then
      return 0
    fi
    [[ "${i}" -lt "${retries}" ]] && sleep 3
  done
  return 1
}

lab_k8s_api_wait() {
  local loops="${LAB_K8S_API_WAIT_LOOPS:-24}"
  local sec="${LAB_K8S_API_WAIT_SEC:-5}"
  local i
  for i in $(seq 1 "${loops}"); do
    if lab_k8s_api_probe; then
      echo "OK: k8s API ready (attempt ${i}/${loops})"
      return 0
    fi
    echo "  [${i}/${loops}] k8s API not ready yet…"
    sleep "${sec}"
  done
  return 1
}

# Lab VMs: k3s kubectl is more reliable than standalone kubectl against 127.0.0.1:6443.
if command -v k3s >/dev/null 2>&1; then
  kubectl() {
    k3s kubectl "$@"
  }
fi

lab_ensure_kubeconfig || true
