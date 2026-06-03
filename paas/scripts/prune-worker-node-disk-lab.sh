#!/usr/bin/env bash
# Prune images on a k3s worker when SSH hostname fails (Harbor runs on worker2).
set -euo pipefail

NODE="${WORKER2_NODE:-worker2}"
echo "==> Prune disk on node ${NODE} via kubectl debug (chroot /host)"

kubectl get node "${NODE}" >/dev/null 2>&1 || {
  echo "FAIL: node ${NODE} not found — kubectl get nodes -o wide" >&2
  exit 1
}

# Ephemeral debug pod — cleans containerd/docker on the node root filesystem.
kubectl debug "node/${NODE}" -it --profile=general --image=busybox:1.36 \
  -- chroot /host sh -c '
    echo "Before:"; df -h / | tail -1
    if command -v crictl >/dev/null 2>&1; then
      crictl rmi --prune 2>/dev/null || true
    fi
    if command -v docker >/dev/null 2>&1; then
      docker system prune -af 2>/dev/null || true
    fi
    echo "After:"; df -h / | tail -1
  ' 2>/dev/null || {
  echo "WARN: kubectl debug failed — on ${NODE} console run:"
  echo "  sudo crictl rmi --prune && sudo docker system prune -af && df -h /"
  exit 1
}

echo "OK: node ${NODE} prune attempted"
