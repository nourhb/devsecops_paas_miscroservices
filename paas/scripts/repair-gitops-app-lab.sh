#!/usr/bin/env bash
# Repair a GitOps Helm app directory (fixes "roll dice app" invalid K8s names from old bootstrap).
set -euo pipefail
PROJECT_SLUG="${1:?usage: repair-gitops-app-lab.sh <project-slug e.g. roll-dice-app> [image-tag]}"
IMAGE_TAG="${2:-655}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
APP_DIR="${GITOPS}/apps/${PROJECT_SLUG}"
REF_CHART="${REPO_ROOT}/paas/gitops/apps/simple-app"
VALUES="${APP_DIR}/values.yaml"
FULLNAME="${ARGOCD_APP_PREFIX}-${PROJECT_SLUG}"
IMAGE="${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_SLUG}:${IMAGE_TAG}"

[[ -d "${GITOPS}/.git" ]] || { echo "ERROR: clone gitops to ${GITOPS}" >&2; exit 1; }
[[ -d "${REF_CHART}" ]] || { echo "ERROR: missing reference chart ${REF_CHART}" >&2; exit 1; }

# shellcheck source=gitops-lab-lib.sh
source "${SCRIPT_DIR}/gitops-lab-lib.sh"
AUTH_URL=""
if [[ -f "${REPO_ROOT}/paas/frontend/docker-compose.env" ]]; then
  GITHUB_TOKEN="$(grep -E '^GITOPS_REPO_TOKEN=' "${REPO_ROOT}/paas/frontend/docker-compose.env" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -n "${GITHUB_TOKEN}" ]] && AUTH_URL="https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git"
fi
echo "==> Reset ${GITOPS} to origin/main (avoid add/add merge conflicts)"
gitops_reset_to_origin_main "${GITOPS}" main "${AUTH_URL}"

echo "==> Repair GitOps chart at ${APP_DIR}"
mkdir -p "${APP_DIR}/templates"
for rel in Chart.yaml templates/_helpers.tpl templates/deployment.yaml templates/deployment-bluegreen.yaml templates/service.yaml templates/ingress.yaml; do
  src="${REF_CHART}/${rel}"
  dest="${APP_DIR}/${rel}"
  mkdir -p "$(dirname "${dest}")"
  sed 's/simple-app/'"${PROJECT_SLUG}"'/g' "${src}" > "${dest}"
done
echo "OK: chart files (slug=${PROJECT_SLUG})"

python3 - "${VALUES}" "${PROJECT_SLUG}" "${FULLNAME}" "${IMAGE}" "${NODE_IP}" <<'PY'
import sys
from pathlib import Path
import yaml
path, slug, fullname, image, node_ip = sys.argv[1:6]
at = image.rfind(":")
repo_path, tag = image[:at], image[at + 1 :]
doc = {
    "nameOverride": slug,
    "fullnameOverride": fullname,
    "deploymentStrategy": "Rolling",
    "image": {
        "repository": repo_path,
        "tag": tag,
        "digest": "",
        "pullPolicy": "IfNotPresent",
    },
    "imagePullSecrets": [{"name": "harbor-regcred"}],
    "service": {"targetPort": 3000},
    "resources": {
        "limits": {"cpu": "200m", "memory": "256Mi"},
        "requests": {"cpu": "25m", "memory": "64Mi"},
    },
    "probes": {
        "readiness": {"initialDelaySeconds": 5, "periodSeconds": 10, "failureThreshold": 6},
        "liveness": {"initialDelaySeconds": 15, "periodSeconds": 20, "failureThreshold": 6},
    },
    "ingress": {
        "enabled": True,
        "className": "traefik",
        "hosts": [{"host": f"{slug}.{node_ip}.nip.io"}],
        "tls": [],
    },
}
Path(path).parent.mkdir(parents=True, exist_ok=True)
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"OK values: fullnameOverride={fullname} image={doc['image']['repository']}:{doc['image']['tag']}")
PY

echo "==> Push GitOps (if token configured)"
if [[ -f "${REPO_ROOT}/paas/frontend/docker-compose.env" ]]; then
  bash "${SCRIPT_DIR}/push-gitops-lab.sh" "fix(gitops): repair ${PROJECT_SLUG} chart slug + values :${IMAGE_TAG}" || \
    echo "WARN: push failed — commit manually in ${GITOPS}"
fi

echo ""
echo "Next on VM:"
echo "  bash paas/scripts/fix-harbor-cosign-realm-lab.sh"
echo "  bash paas/scripts/apply-kyverno-cosign-lab.sh"
echo "  kubectl annotate application ${FULLNAME} -n argocd argocd.argoproj.io/refresh=hard --overwrite"
echo "  bash paas/scripts/heal-project-deploy-lab.sh ${PROJECT_SLUG} ${IMAGE_TAG} 3000"
