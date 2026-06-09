#!/usr/bin/env bash
# Set blue.image.tag, green.image.tag, and top-level image.tag to the same build (Argo uses slot tags).
set -euo pipefail

PROJECT_NAME="${1:?usage: fix-gitops-blue-green-tags-lab.sh <projectName> <tag>}"
TAG="${2:?usage: fix-gitops-blue-green-tags-lab.sh <projectName> <tag>}"
if ! [[ "${TAG}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: tag must be numeric Jenkins build number, got: ${TAG}" >&2
  exit 1
fi
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

python3 - "${VALUES}" "${TAG}" "${NODE_IP}" "${PROJECT_NAME}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.stderr.write("pip3 install pyyaml\n")
    raise
path, tag, node_ip, name = sys.argv[1:5]
repo = f"{node_ip}:30002/paas/{name}"
doc = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
for slot in ("blue", "green"):
    block = doc.setdefault(slot, {})
    img = block.setdefault("image", {})
    img["repository"] = repo
    img["tag"] = str(tag)
top = doc.get("image") if isinstance(doc.get("image"), dict) else {}
top.setdefault("repository", repo)
top["tag"] = str(tag)
top.setdefault("pullPolicy", "IfNotPresent")
doc["image"] = top
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"OK: {path} → blue/green/top-level tag={tag}")
PY

echo "==> git commit + push"
pushd "${GITOPS}" >/dev/null
git add "apps/${PROJECT_NAME}/values.yaml"
git diff --cached --stat
git commit -m "fix(gitops): align ${PROJECT_NAME} blue+green+top image tag :${TAG}" || true
popd >/dev/null
bash "${SCRIPT_DIR}/push-gitops-lab.sh"

# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
APP="paas-${PROJECT_NAME}"
echo "==> Argo sync ${APP}"
argo_sync_app_lab "${APP}" || true
argo_wait_app_lab "${APP}" 300 || true

echo "==> deployment images"
kubectl get deploy -n "${PROJECT_NAME}" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true
