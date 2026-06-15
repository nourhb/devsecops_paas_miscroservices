#!/usr/bin/env bash
# Configure k3s/containerd to pull Harbor over HTTP (lab). Run on control-plane; restarts k3s agents.
set -euo pipefail
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
HARBOR_NIP="harbor.${NODE_IP}.nip.io"
REGISTRIES_FILE="${REGISTRIES_FILE:-/etc/rancher/k3s/registries.yaml}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"

write_registries() {
  local target="$1"
  sudo mkdir -p "$(dirname "${target}")"
  sudo tee "${target}" >/dev/null <<EOF
mirrors:
  "${HARBOR_NIP}:${HARBOR_PORT}":
    endpoint:
      - "http://${HARBOR_NIP}:${HARBOR_PORT}"
  "${NODE_IP}:${HARBOR_PORT}":
    endpoint:
      - "http://${NODE_IP}:${HARBOR_PORT}"
configs:
  "${HARBOR_NIP}:${HARBOR_PORT}":
    auth:
      username: ${HARBOR_USER}
      password: ${HARBOR_PASS}
    tls:
      insecure_skip_verify: true
  "${NODE_IP}:${HARBOR_PORT}":
    auth:
      username: ${HARBOR_USER}
      password: ${HARBOR_PASS}
    tls:
      insecure_skip_verify: true
EOF
  echo "OK wrote ${target}"
}

write_registries "${REGISTRIES_FILE}"

if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet k3s 2>/dev/null; then
    echo "==> Restart k3s (control-plane)"
    sudo systemctl restart k3s
  fi
  if systemctl is-active --quiet k3s-agent 2>/dev/null; then
    echo "==> Restart k3s-agent"
    sudo systemctl restart k3s-agent
  fi
fi

echo "OK: Harbor HTTP mirrors for ${NODE_IP}:${HARBOR_PORT} and ${HARBOR_NIP}:${HARBOR_PORT}"
echo "    Re-run on worker nodes if pulls still fail (copy ${REGISTRIES_FILE} + restart k3s-agent)."
