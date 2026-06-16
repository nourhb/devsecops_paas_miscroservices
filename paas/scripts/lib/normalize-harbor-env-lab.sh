#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"

if [[ ! -f "${ENV_FILE}" ]]; then
  exit 0
fi

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
