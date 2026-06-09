#!/usr/bin/env bash
# Manual blue-green promote for lab (mirrors PaaS: inactive slot → wait → flip).
set -euo pipefail

PROJECT_NAME="${1:?usage: promote-paas-blue-green-lab.sh <projectName> <jenkinsBuildNumber>}"
TAG="${2:?usage: promote-paas-blue-green-lab.sh <projectName> <jenkinsBuildNumber>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"
REPO="${NODE_IP}:30002/paas/${PROJECT_NAME}"

[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"

python3 - "${VALUES}" "${TAG}" "${REPO}" <<'PY'
import sys
from pathlib import Path
import yaml

path, tag, repo = sys.argv[1:4]
doc = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
doc["deploymentStrategy"] = "BlueGreen"
active = "green" if doc.get("activeSlot") == "green" else "blue"
inactive = "green" if active == "blue" else "blue"
for slot in ("blue", "green"):
    block = doc.setdefault(slot, {})
    img = block.setdefault("image", {})
    if not img.get("repository"):
        legacy = doc.get("image") or {}
        img["repository"] = legacy.get("repository") or repo
    if slot == inactive:
        img["tag"] = str(tag)
        img["digest"] = ""
    elif not img.get("tag") and not img.get("digest"):
        legacy = doc.get("image") or {}
        img["tag"] = str(legacy.get("tag") or "latest")
doc["activeSlot"] = active
act = doc[active]["image"]
doc["image"] = {
    "repository": act.get("repository") or repo,
    "tag": act.get("tag", ""),
    "digest": act.get("digest", ""),
    "pullPolicy": "IfNotPresent",
}
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"inactive={inactive} tag={tag} active(traffic)={active}")
PY

pushd "${GITOPS}" >/dev/null
git add "apps/${PROJECT_NAME}/values.yaml"
git commit -m "chore(gitops): ${PROJECT_NAME} blue-green deploy :${TAG} (inactive)" || true
popd >/dev/null
bash "${SCRIPT_DIR}/push-gitops-lab.sh" || echo "WARN: git push failed — set GITOPS_REPO_TOKEN in docker-compose.env and re-run push-gitops-lab.sh"

APP="${ARGOCD_APP_PREFIX}-${PROJECT_NAME}"
argo_sync_app_lab "${APP}" || true
argo_wait_app_lab "${APP}" 300 || true

INACTIVE="$(python3 - "${VALUES}" <<'PY'
import sys, yaml
from pathlib import Path
doc = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8")) or {}
active = "green" if doc.get("activeSlot") == "green" else "blue"
print("green" if active == "blue" else "blue")
PY
)"
DEPLOY="${APP}-${PROJECT_NAME}-${INACTIVE}"
echo "==> Wait deployment ${DEPLOY}"
kubectl rollout status "deploy/${DEPLOY}" -n "${PROJECT_NAME}" --timeout=300s

python3 - "${VALUES}" <<'PY'
import sys
from pathlib import Path
import yaml

path = Path(sys.argv[1])
doc = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
active = "green" if doc.get("activeSlot") == "green" else "blue"
next_slot = "green" if active == "blue" else "blue"
doc["activeSlot"] = next_slot
act = doc[next_slot]["image"]
doc["image"] = {
    "repository": act.get("repository"),
    "tag": act.get("tag", ""),
    "digest": act.get("digest", ""),
    "pullPolicy": "IfNotPresent",
}
path.write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"flipped traffic to {next_slot}")
PY

pushd "${GITOPS}" >/dev/null
git add "apps/${PROJECT_NAME}/values.yaml"
git commit -m "chore(gitops): ${PROJECT_NAME} blue-green traffic switch" || true
popd >/dev/null
bash "${SCRIPT_DIR}/push-gitops-lab.sh" || echo "WARN: git push failed — run: bash paas/scripts/push-gitops-lab.sh"

argo_sync_app_lab "${APP}" || true
argo_wait_app_lab "${APP}" 300 || true
echo "Done. URL: http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"
