#!/usr/bin/env bash
# Wait for / start k3s — restart only if API still dead after a short wait.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lab-kube-env.sh
source "${SCRIPT_DIR}/lab-kube-env.sh"

LAB_K3S_WAIT_LOOPS="${LAB_K3S_WAIT_LOOPS:-12}"
LAB_K3S_WAIT_SEC="${LAB_K3S_WAIT_SEC:-5}"

lab_k3s_wait_api() {
  local i
  for i in $(seq 1 "${LAB_K3S_WAIT_LOOPS}"); do
    if lab_k8s_api_ready; then
      echo "OK: k3s API ready (attempt ${i}/${LAB_K3S_WAIT_LOOPS})"
      return 0
    fi
    echo "  [${i}/${LAB_K3S_WAIT_LOOPS}] k3s API not ready yet…"
    sleep "${LAB_K3S_WAIT_SEC}"
  done
  return 1
}

lab_k3s_service_active() {
  timeout 20 systemctl is-active k3s >/dev/null 2>&1
}

if [[ "${LAB_K3S_FORCE_RESTART:-}" == "1" ]]; then
  echo "WARN: LAB_K3S_FORCE_RESTART=1 — restarting k3s"
  timeout 120 sudo systemctl restart k3s 2>/dev/null || sudo systemctl restart k3s || true
  lab_k3s_wait_api && exit 0
fi

if lab_k8s_api_ready; then
  echo "OK: k3s API already up"
  exit 0
fi

echo "WARN: k3s API not reachable"
if lab_k3s_service_active; then
  echo "==> k3s.service is active — wait up to $(( LAB_K3S_WAIT_LOOPS * LAB_K3S_WAIT_SEC ))s before restart"
  if lab_k3s_wait_api; then
    exit 0
  fi
  echo "WARN: k3s active but API still down — restarting k3s once"
  timeout 120 sudo systemctl restart k3s 2>/dev/null || sudo systemctl restart k3s || true
  if lab_k3s_wait_api; then
    exit 0
  fi
else
  echo "WARN: k3s.service not active — starting"
  timeout 120 sudo systemctl start k3s 2>/dev/null || sudo systemctl start k3s || true
  if lab_k3s_wait_api; then
    exit 0
  fi
  echo "WARN: start did not bring API up — restarting k3s once"
  timeout 120 sudo systemctl restart k3s 2>/dev/null || sudo systemctl restart k3s || true
  if lab_k3s_wait_api; then
    exit 0
  fi
fi

echo "ERROR: k3s API still down" >&2
echo "  k3s kubectl get nodes" >&2
echo "  sudo systemctl status k3s --no-pager" >&2
echo "  sudo journalctl -u k3s -n 40 --no-pager" >&2
exit 1
