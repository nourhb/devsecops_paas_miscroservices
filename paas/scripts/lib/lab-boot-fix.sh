#!/usr/bin/env bash
# One-shot: install boot service + kubeconfig + start recover now.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " lab-boot-fix — VM auto-start + recover now"
echo "=============================================="

cd "${REPO_ROOT}"

if [[ -n "$(git status --porcelain paas/scripts/ 2>/dev/null)" ]]; then
  echo "WARN: local edits under paas/scripts/ — stashing before pull"
  git stash push -m "lab-boot-fix-$(date +%Y%m%d)" -- paas/scripts/ 2>/dev/null || true
fi
git pull -q 2>/dev/null || echo "WARN: git pull skipped"

chmod +x paas/scripts/lab.sh paas/scripts/lib/*.sh 2>/dev/null || true

bash paas/scripts/lib/lab-k3s-ensure.sh || {
  echo "ERROR: k3s failed to start — try: sudo systemctl restart k3s" >&2
  exit 1
}

if [[ ! -r "${HOME}/.kube/config" && -f /etc/rancher/k3s/k3s.yaml ]]; then
  mkdir -p "${HOME}/.kube"
  if cp /etc/rancher/k3s/k3s.yaml "${HOME}/.kube/config" 2>/dev/null; then
    chmod 600 "${HOME}/.kube/config"
  else
    sudo install -d -o "${USER}" -g "${USER}" -m 700 "${HOME}/.kube"
    sudo install -o "${USER}" -g "${USER}" -m 600 "${HOME}/.kube/config" /etc/rancher/k3s/k3s.yaml
  fi
  echo "OK: kubeconfig at ${HOME}/.kube/config"
fi

export KUBECONFIG="${HOME}/.kube/config"
if ! bash paas/scripts/lab.sh boot-install; then
  echo "ERROR: boot-install failed" >&2
  exit 1
fi

echo ""
echo "==> Recover PaaS now (direct — not via systemd, avoids k3s restart race)"
bash paas/scripts/lab.sh start

echo ""
echo "==> Waiting for PaaS health (up to 5 min)…"
for i in $(seq 1 30); do
  if bash paas/scripts/lab.sh health; then
    echo ""
    echo "=============================================="
    echo " OK — PaaS ready: http://${NODE_IP}:30100/login"
    echo " Boot service enabled — should recover after VM reboot"
    echo " Log: /var/log/paas-lab-start.log"
    echo "=============================================="
    exit 0
  fi
  echo "  [${i}/30] not ready yet…"
  sleep 10
done

echo ""
echo "WARN: health still failing — run manually:"
echo "  bash paas/scripts/lab.sh start"
echo "  tail -50 /var/log/paas-lab-start.log"
bash paas/scripts/lab.sh boot-status
exit 1
