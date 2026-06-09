#!/usr/bin/env bash
# Bump GitOps Helm image tag after Jenkins SUCCESS (cluster often lags Harbor push).
set -euo pipefail

PROJECT_NAME="${1:?usage: promote-paas-image-tag-lab.sh <projectName> <jenkinsBuildNumber>}"
TAG="${2:?usage: promote-paas-image-tag-lab.sh <projectName> <jenkinsBuildNumber>}"

if ! [[ "${TAG}" =~ ^[0-9]+$ ]]; then
  echo "ERROR: tag must be a Jenkins build number (digits only), got: ${TAG}" >&2
  echo "  Wait for build SUCCESS, then: bash paas/scripts/promote-paas-image-tag-lab.sh ${PROJECT_NAME} 331" >&2
  exit 1
fi

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
repo = f"{node_ip}:30002/paas/{name}"
doc = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
for slot in ("blue", "green"):
    block = doc.setdefault(slot, {})
    img = block.setdefault("image", {})
    img["repository"] = repo
    img["tag"] = str(tag)
img = doc.get("image") if isinstance(doc.get("image"), dict) else {}
img.setdefault("repository", repo)
img["tag"] = str(tag)
img.setdefault("pullPolicy", "IfNotPresent")
doc["image"] = img
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"image: {repo}:{tag} (blue+green+top-level)")
PY

echo "==> Git commit + push"
pushd "${GITOPS}" >/dev/null
git add "apps/${PROJECT_NAME}/values.yaml"
if git diff --cached --quiet; then
  echo "No changes"
  popd >/dev/null
else
  git commit -m "chore(gitops): bump ${PROJECT_NAME} image to :${TAG}"
  popd >/dev/null
  bash "${SCRIPT_DIR}/push-gitops-lab.sh"
fi

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
ROLLED=0
for _ in $(seq 1 30); do
  cur="$(kubectl get deploy -n "${PROJECT_NAME}" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "  ${cur:-<none>}"
  if [[ "${cur}" == *":${TAG}" ]]; then
    ROLLED=1
    break
  fi
  sleep 10
done

if [[ "${ROLLED}" != "1" ]]; then
  echo ""
  echo "WARN: cluster still not on :${TAG} — GitOps chart likely uses blue.image.tag / green.image.tag"
  echo "==> FORCE kubectl set image on all deployments in ${PROJECT_NAME}"
  for dep in $(kubectl get deploy -n "${PROJECT_NAME}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    cname="$(kubectl get deploy "${dep}" -n "${PROJECT_NAME}" -o jsonpath='{.spec.template.spec.containers[0].name}')"
    kubectl set image "deployment/${dep}" -n "${PROJECT_NAME}" "${cname}=${IMAGE}"
  done
  kubectl rollout status deployment -n "${PROJECT_NAME}" --timeout=300s || true
  cur="$(kubectl get deploy -n "${PROJECT_NAME}" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  echo "  after force: ${cur:-<none>}"
  echo ""
  echo "Re-run promote with updated script (sets blue+green in values.yaml):"
  echo "  bash paas/scripts/promote-paas-image-tag-lab.sh ${PROJECT_NAME} ${TAG}"
fi

echo ""
echo "Sign image for Security UI:"
echo "  cosign sign --yes --allow-insecure-registry --key ${REPO_ROOT}/paas/.lab-cosign/cosign.key ${IMAGE}"
echo "Open: http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"
