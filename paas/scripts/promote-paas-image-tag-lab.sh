#!/usr/bin/env bash
# Bump GitOps Helm image tag after Jenkins SUCCESS (cluster often lags Harbor push).
set -euo pipefail

PROJECT_NAME="${1:?usage: promote-paas-image-tag-lab.sh <projectName> <jenkinsBuildNumber>}"
TAG="${2:?usage: promote-paas-image-tag-lab.sh <projectName> <jenkinsBuildNumber>}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"

[[ -d "${GITOPS}/.git" ]] || { echo "ERROR: clone gitops: git clone https://github.com/nourhb/gitops.git ${GITOPS}" >&2; exit 1; }
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

if [[ -f "${ENV_FILE}" && -z "${GITHUB_TOKEN:-}" ]]; then
  tok="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -n "${tok}" ]] && export GITHUB_TOKEN="${tok}"
fi

echo "==> Set image.tag=${TAG} in ${VALUES}"
python3 - "${VALUES}" "${TAG}" "${NODE_IP}" "${PROJECT_NAME}" <<'PY'
import sys
from pathlib import Path
try:
    import yaml
except ImportError:
    sys.stderr.write("pip3 install pyyaml\n")
    raise
path, tag, node_ip, name = sys.argv[1:5]
doc = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
img = doc.get("image") if isinstance(doc.get("image"), dict) else {}
img.setdefault("repository", f"{node_ip}:30002/paas/{name}")
img["tag"] = str(tag)
doc["image"] = img
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"image: {img['repository']}:{tag}")
PY

echo "==> Git commit + push"
pushd "${GITOPS}" >/dev/null
git add "apps/${PROJECT_NAME}/values.yaml"
if git diff --cached --quiet; then
  echo "No changes"
else
  git commit -m "chore(gitops): bump ${PROJECT_NAME} image to :${TAG}"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
  else
    echo "WARN: set GITOPS_REPO_TOKEN in docker-compose.env and git push"
  fi
fi
popd >/dev/null

# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
APP="${ARGOCD_APP_PREFIX}-${PROJECT_NAME}"
echo "==> Argo sync ${APP}"
if kubectl get application "${APP}" -n argocd >/dev/null 2>&1; then
  argo_sync_app_lab "${APP}" || true
  argo_wait_app_lab "${APP}" 300 || true
else
  echo "WARN: Argo app ${APP} not found"
fi

IMAGE="${NODE_IP}:30002/paas/${PROJECT_NAME}:${TAG}"
echo "==> Wait for deployment image"
for _ in $(seq 1 30); do
  cur="$(kubectl get deploy -n "${PROJECT_NAME}" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "  ${cur:-<none>}"
  [[ "${cur}" == *":${TAG}" ]] && break
  sleep 10
done

echo ""
echo "Sign image for Security UI:"
echo "  cosign sign --yes --allow-insecure-registry --key ${REPO_ROOT}/paas/.lab-cosign/cosign.key ${IMAGE}"
echo "Open: http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"
