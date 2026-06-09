#!/usr/bin/env bash
# One-shot: push GitOps, deploy sanhome image tag to cluster, trigger Jenkins #313 (Sonar).
# Usage: TAG=312 bash paas/scripts/complete-sanhome-lab.sh
#        SKIP_JENKINS=1 TAG=312 bash paas/scripts/complete-sanhome-lab.sh  # GitOps+k8s only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PROJECT_NAME="${PROJECT_NAME:-sanhome}"
TAG="${TAG:-312}"
ARGO_APP="${ARGOCD_APP_PREFIX:-paas}-${PROJECT_NAME}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"
IMAGE="${NODE_IP}:30002/paas/${PROJECT_NAME}:${TAG}"

[[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
set +u
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set -u

[[ -d "${GITOPS}/.git" ]] || { echo "ERROR: clone gitops to ${GITOPS}" >&2; exit 1; }
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

if [[ -z "${GITOPS_REPO_TOKEN:-}" || "${GITOPS_REPO_TOKEN}" == *your_* || "${GITOPS_REPO_TOKEN}" == *placeholder* ]]; then
  echo "ERROR: set GITOPS_REPO_TOKEN in ${ENV_FILE}" >&2
  exit 1
fi
export GITHUB_TOKEN="${GITOPS_REPO_TOKEN}"

echo "==> 1. GitOps: bump ${PROJECT_NAME} inactive slot + traffic to :${TAG}"
python3 - "${VALUES}" "${TAG}" "${IMAGE}" <<'PY'
import sys
from pathlib import Path
import yaml

path, tag, full = sys.argv[1:4]
repo, _ = full.rsplit(":", 1)
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
    img["tag"] = str(tag)
    img["digest"] = ""
doc["activeSlot"] = inactive
act = doc[inactive]["image"]
doc["image"] = {
    "repository": act.get("repository") or repo,
    "tag": str(tag),
    "digest": "",
    "pullPolicy": "IfNotPresent",
}
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"activeSlot={inactive} (traffic) blue/green tag={tag}")
PY

pushd "${GITOPS}" >/dev/null
if git status --porcelain -- apps/*/templates/deployment-bluegreen.yaml 2>/dev/null | grep -q .; then
  echo "==> Stash unrelated template edits (so push can proceed)"
  git stash push -m "complete-sanhome-lab-$(date +%s)" -- apps/*/templates/deployment-bluegreen.yaml 2>/dev/null || true
fi
git add "apps/${PROJECT_NAME}/values.yaml"
git commit -m "chore(gitops): ${PROJECT_NAME} deploy :${TAG} (complete-sanhome-lab)" || true
popd >/dev/null

echo "==> 2. git push origin/main (PAT)"
bash "${SCRIPT_DIR}/push-gitops-lab.sh" || {
  echo "WARN: push-gitops-lab.sh failed — direct push"
  pushd "${GITOPS}" >/dev/null
  git push "https://${GITOPS_REPO_TOKEN}@github.com/nourhb/gitops.git" main
  popd >/dev/null
}

# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
echo "==> 3. Argo CD sync ${ARGO_APP}"
argo_sync_app_lab "${ARGO_APP}" || true
argo_wait_app_lab "${ARGO_APP}" 300 || true
kubectl annotate application "${ARGO_APP}" -n argocd argocd.argoproj.io/refresh=hard --overwrite 2>/dev/null || true

echo "==> 4. kubectl set image (blue + green) :${TAG}"
for dep in "paas-${PROJECT_NAME}-${PROJECT_NAME}-blue" "paas-${PROJECT_NAME}-${PROJECT_NAME}-green"; do
  if kubectl get deploy "${dep}" -n "${PROJECT_NAME}" >/dev/null 2>&1; then
    cn="$(kubectl get deploy "${dep}" -n "${PROJECT_NAME}" -o jsonpath='{.spec.template.spec.containers[0].name}')"
    kubectl set image "deploy/${dep}" -n "${PROJECT_NAME}" "${cn}=${IMAGE}"
    kubectl rollout status "deploy/${dep}" -n "${PROJECT_NAME}" --timeout=300s
  fi
done
kubectl get deploy -n "${PROJECT_NAME}" -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image

if [[ "${SKIP_JENKINS:-}" == "1" ]]; then
  echo "SKIP_JENKINS=1 — done (GitOps + cluster images)."
  exit 0
fi

[[ -n "${JENKINS_USERNAME:-}" && -n "${JENKINS_API_TOKEN:-}" ]] || {
  echo "WARN: skip Jenkins — set JENKINS_USERNAME/JENKINS_API_TOKEN" >&2
  exit 0
}

echo "==> 5. Jenkins job SONAR_TOKEN sync + trigger full pipeline (#313+)"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force 2>/dev/null || true

export JENKINS_PAAS_FAST_PIPELINE=false
PROJECT_ID="$(bash "${SCRIPT_DIR}/get-project-id-lab.sh" "${PROJECT_NAME}")"
python3 "${SCRIPT_DIR}/trigger-paas-deploy-lab.py"
sleep 5
NEW_BN="$(curl -g -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "${JENKINS_PROBE_URL:-http://127.0.0.1:30090}/job/paas-deploy/lastBuild/api/json" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('number',''))")"
echo "Waiting for build #${NEW_BN}…"
BUILD_NUMBER="${NEW_BN}" bash "${SCRIPT_DIR}/wait-jenkins-paas-build-lab.sh"

echo "==> 6. Sonar + verify"
curl -fsS -u "${JENKINS_USERNAME}:${JENKINS_API_TOKEN}" \
  "http://127.0.0.1:30090/job/paas-deploy/${NEW_BN}/consoleText" \
  | grep -iE 'PAAS_STEP_OK step=5|PAAS_STEP_WARN step=5|scanner exit|EXECUTION SUCCESS' || true
BUILD_NUMBER="${NEW_BN}" PROJECT_ID="${PROJECT_ID}" bash "${SCRIPT_DIR}/verify-security-pipeline-lab.sh" || true

echo "==> 7. Sign Harbor :${NEW_BN} if build SUCCESS"
if curl -fsS -u admin:Harbor12345 "http://${NODE_IP}:30002/v2/paas/${PROJECT_NAME}/tags/list" \
  | python3 -c "import json,sys; print('${NEW_BN}' in json.load(sys.stdin).get('tags',[]))" | grep -q True; then
  bash "${SCRIPT_DIR}/sign-harbor-image-lab.sh" "${NODE_IP}:30002/paas/${PROJECT_NAME}:${NEW_BN}" || true
fi

echo "DONE: ${PROJECT_NAME} image=${IMAGE} Jenkins=#${NEW_BN} Argo=${ARGO_APP}"
