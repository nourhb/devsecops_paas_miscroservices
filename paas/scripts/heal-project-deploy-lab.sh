#!/usr/bin/env bash
# Fix a project after Jenkins SUCCESS but PaaS FAILED (pods not ready / wrong port / stale BlueGreen).
# Usage: bash paas/scripts/heal-project-deploy-lab.sh <projectName> <jenkinsBuildNumber> [targetPort]
set -euo pipefail

PROJECT_NAME="${1:?usage: heal-project-deploy-lab.sh <projectName> <jenkinsBuildNumber> [80|8000|3000]}"
TAG="${2:?usage: heal-project-deploy-lab.sh <projectName> <jenkinsBuildNumber>}"
TARGET_PORT="${3:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"
NS="${PROJECT_NAME}"
APP="${ARGOCD_APP_PREFIX}-${PROJECT_NAME}"
IMAGE="${NODE_IP}:30002/paas/${PROJECT_NAME}:${TAG}"
URL="http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"

# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"

if [[ -z "${TARGET_PORT}" ]]; then
  case "${PROJECT_NAME}" in
    *angular*|*demo-angular*) TARGET_PORT=80 ;;
    *python*|docker-demo*) TARGET_PORT=8000 ;;
    *) TARGET_PORT=3000 ;;
  esac
fi

[[ -d "${GITOPS}/.git" ]] || { echo "ERROR: clone gitops to ${GITOPS}" >&2; exit 1; }
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

echo "==> Heal ${PROJECT_NAME} build :${TAG} targetPort=${TARGET_PORT}"
echo "    Image: ${IMAGE}"
echo "    URL:   ${URL}"

echo "==> Patch ${VALUES} (Rolling + image + targetPort)"
python3 - "${VALUES}" "${TAG}" "${NODE_IP}" "${PROJECT_NAME}" "${TARGET_PORT}" <<'PY'
import sys
from pathlib import Path
import yaml

path, tag, node_ip, name, port = sys.argv[1:6]
port = int(port)
repo = f"{node_ip}:30002/paas/{name}"
doc = yaml.safe_load(Path(path).read_text(encoding="utf-8")) or {}
doc["deploymentStrategy"] = "Rolling"
for k in ("activeSlot", "blue", "green"):
    doc.pop(k, None)
img = doc.get("image") if isinstance(doc.get("image"), dict) else {}
img["repository"] = repo
img["tag"] = str(tag)
img["digest"] = ""
img["pullPolicy"] = "IfNotPresent"
doc["image"] = img
svc = doc.get("service") if isinstance(doc.get("service"), dict) else {}
svc["targetPort"] = port
doc["service"] = svc
if not doc.get("imagePullSecrets"):
    doc["imagePullSecrets"] = [{"name": "harbor-regcred"}]
if not doc.get("resources"):
    doc["resources"] = {
        "limits": {"cpu": "300m", "memory": "384Mi"},
        "requests": {"cpu": "50m", "memory": "128Mi"},
    }
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"OK values: Rolling image={repo}:{tag} service.targetPort={port}")
PY

echo "==> Push GitOps to GitHub"
bash "${SCRIPT_DIR}/push-gitops-lab.sh" "chore(heal): ${PROJECT_NAME} :${TAG} port ${TARGET_PORT}"

echo "==> Remove stale blue/green deployments (free cluster capacity)"
for dep in $(kubectl get deploy -n "${NS}" -o name 2>/dev/null | grep -E '\-(blue|green)$' || true); do
  echo "  delete ${dep}"
  kubectl delete -n "${NS}" "${dep}" --wait=false 2>/dev/null || true
done

echo "==> Argo sync ${APP}"
kubectl patch application "${APP}" -n argocd --type json \
  -p='[{"op": "remove", "path": "/operation"}]' 2>/dev/null || true
kubectl annotate application "${APP}" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
argo_sync_app_lab "${APP}" || true
argo_wait_app_lab "${APP}" 360 || true

echo "==> Cluster state"
kubectl get deploy,pods -n "${NS}" -o wide 2>/dev/null || true

echo "==> Force image on rolling deployment(s) if still stale"
for dep in $(kubectl get deploy -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${dep}" == *-blue ]] || [[ "${dep}" == *-green ]] && continue
  cname="$(kubectl get deploy "${dep}" -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].name}')"
  echo "  set image ${dep}/${cname}=${IMAGE}"
  kubectl set image "deployment/${dep}" -n "${NS}" "${cname}=${IMAGE}" 2>/dev/null || true
  kubectl patch deployment "${dep}" -n "${NS}" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/ports/0/containerPort\",\"value\":${TARGET_PORT}}]" 2>/dev/null || true
done

echo "==> Wait rollout"
kubectl rollout status deployment -n "${NS}" --timeout=300s 2>/dev/null || true

echo "==> Pod events (last errors)"
kubectl get pods -n "${NS}" -o wide 2>/dev/null || true
kubectl describe pods -n "${NS}" 2>/dev/null | tail -30 || true

HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo '?')"
echo ""
echo "HTTP ${URL} => ${HTTP}"
if [[ "${HTTP}" =~ ^[23] ]]; then
  echo "OK — open ${URL}"
else
  echo "WARN — still not HTTP 2xx/3xx. Check: kubectl logs -n ${NS} -l app.kubernetes.io/instance=${APP} --tail=80"
fi
