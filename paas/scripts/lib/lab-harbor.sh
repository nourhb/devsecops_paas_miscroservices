#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_NS="${HARBOR_NS:-harbor}"
HARBOR_RELEASE="${HARBOR_RELEASE:-harbor}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
REGISTRY="${HARBOR_HOST}:${HARBOR_NODEPORT}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

harbor_normalize_env() {
  [[ -f "${ENV_FILE}" ]] || return 0
  python3 - "${ENV_FILE}" "${NODE_IP}" "${HARBOR_NODEPORT}" <<'PY'
import re
import sys
from pathlib import Path

path, node_ip, port = sys.argv[1:4]
nip_host = f"harbor.{node_ip}.nip.io:{port}"
nip_base = f"http://{nip_host}"
text = Path(path).read_text(encoding="utf-8")
lines = text.splitlines()
out = []
ipv4 = re.compile(r"^(\d{1,3}\.){3}\d{1,3}(:\d+)?$")
changed = False
for line in lines:
    if line.startswith("HARBOR_REGISTRY="):
        val = line.split("=", 1)[1].strip().strip('"').strip("'")
        host = val.replace("http://", "").replace("https://", "").split("/")[0]
        if ipv4.match(host):
            line = f"HARBOR_REGISTRY={nip_host}"
            changed = True
    elif line.startswith("HARBOR_BASE_URL="):
        val = line.split("=", 1)[1].strip().strip('"').strip("'")
        host = val.replace("http://", "").replace("https://", "").split("/")[0]
        if ipv4.match(host):
            line = f"HARBOR_BASE_URL={nip_base}"
            changed = True
    out.append(line)
if changed:
    Path(path).write_text("\n".join(out) + ("\n" if text.endswith("\n") else ""), encoding="utf-8")
    print(f"OK normalized Harbor env in {path}")
PY
}

harbor_configure_k3s() {
  local registries_file="${REGISTRIES_FILE:-/etc/rancher/k3s/registries.yaml}"
  local harbor_user="${HARBOR_USER:-admin}"
  local harbor_pass="${HARBOR_PASS:-Harbor12345}"
  sudo mkdir -p "$(dirname "${registries_file}")"
  sudo tee "${registries_file}" >/dev/null <<EOF
mirrors:
  "${HARBOR_HOST}:${HARBOR_NODEPORT}":
    endpoint:
      - "http://${HARBOR_HOST}:${HARBOR_NODEPORT}"
  "${NODE_IP}:${HARBOR_NODEPORT}":
    endpoint:
      - "http://${NODE_IP}:${HARBOR_NODEPORT}"
configs:
  "${HARBOR_HOST}:${HARBOR_NODEPORT}":
    auth:
      username: ${harbor_user}
      password: ${harbor_pass}
    tls:
      insecure_skip_verify: true
  "${NODE_IP}:${HARBOR_NODEPORT}":
    auth:
      username: ${harbor_user}
      password: ${harbor_pass}
    tls:
      insecure_skip_verify: true
EOF
  echo "OK wrote ${registries_file}"
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
  echo "OK: Harbor HTTP mirrors for ${NODE_IP}:${HARBOR_NODEPORT} and ${HARBOR_HOST}:${HARBOR_NODEPORT}"
}

harbor_fix_cosign_realm() {
  local external_url="http://${HARBOR_HOST}:${HARBOR_NODEPORT}"
  if command -v helm >/dev/null 2>&1 && helm status "${HARBOR_RELEASE}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    helm upgrade "${HARBOR_RELEASE}" harbor/harbor -n "${HARBOR_NS}" --reuse-values \
      --set "externalURL=${external_url}"
  else
    echo "WARN: helm release ${HARBOR_RELEASE} not found in ${HARBOR_NS}" >&2
    return 1
  fi
}

harbor_probe() {
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 "http://${REGISTRY}/v2/" 2>/dev/null || echo "000"
}

harbor_recover() {
  echo "==> Harbor registry recover (${REGISTRY})"
  harbor_normalize_env || true
  harbor_fix_cosign_realm || true
  local hc
  hc="$(harbor_probe)"
  if [[ "${hc}" == "200" || "${hc}" == "401" ]]; then
    echo "OK: Harbor /v2/ already healthy (HTTP ${hc})"
    return 0
  fi
  echo "Harbor /v2/ HTTP ${hc} — restarting core registry workloads"
  kubectl get pods -n "${HARBOR_NS}" -o wide 2>/dev/null || true
  for deploy in harbor-nginx harbor-registry harbor-core; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      echo "==> rollout restart deployment/${deploy} -n ${HARBOR_NS}"
      kubectl rollout restart "deployment/${deploy}" -n "${HARBOR_NS}" || true
    fi
  done
  for deploy in harbor-nginx harbor-registry harbor-core; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      kubectl rollout status "deployment/${deploy}" -n "${HARBOR_NS}" --timeout=300s || true
    fi
  done
  for i in $(seq 1 30); do
    hc="$(harbor_probe)"
    if [[ "${hc}" == "200" || "${hc}" == "401" ]]; then
      echo "OK: Harbor /v2/ recovered (HTTP ${hc})"
      return 0
    fi
    echo "wait ${i}/30 — Harbor /v2/ HTTP ${hc}"
    sleep 10
  done
  echo "ERROR: Harbor still unhealthy at http://${REGISTRY}/v2/" >&2
  kubectl get pods -n "${HARBOR_NS}" 2>/dev/null || true
  kubectl get events -n "${HARBOR_NS}" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
  return 1
}

harbor_bootstrap() {
  harbor_normalize_env || true
  harbor_configure_k3s || true
  harbor_recover || true
  harbor_fix_cosign_realm || true
}

cmd="${1:-recover}"
case "${cmd}" in
  normalize) harbor_normalize_env ;;
  configure) harbor_configure_k3s ;;
  fix-realm) harbor_fix_cosign_realm ;;
  recover) harbor_recover ;;
  bootstrap) harbor_bootstrap ;;
  *)
    echo "usage: lab-harbor.sh [normalize|configure|fix-realm|recover|bootstrap]" >&2
    exit 1 ;;
esac
