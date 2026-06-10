#!/usr/bin/env bash
# Fix a project after Jenkins SUCCESS but PaaS FAILED (pods not ready / wrong port / stale BlueGreen).
# Usage: bash paas/scripts/heal-project-deploy-lab.sh <projectName> <jenkinsBuildNumber> [targetPort]
set -uo pipefail

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
# shellcheck source=lib/gitops-ensure-main.sh
source "${SCRIPT_DIR}/lib/gitops-ensure-main.sh"

if [[ -z "${TARGET_PORT}" ]]; then
  case "${PROJECT_NAME}" in
    *angular*|*demo-angular*) TARGET_PORT=80 ;;
    *python*|docker-demo*) TARGET_PORT=8000 ;;
    *) TARGET_PORT=3000 ;;
  esac
fi

[[ -d "${GITOPS}/.git" ]] || { echo "ERROR: clone gitops to ${GITOPS}" >&2; exit 1; }
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

free_namespace_capacity() {
  local ns="$1"
  echo "==> Free cluster capacity in namespace ${ns}"
  for dep in $(kubectl get deploy -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    if [[ "${dep}" == *-blue ]] || [[ "${dep}" == *-green ]]; then
      echo "  delete deployment/${dep}"
      kubectl delete deployment "${dep}" -n "${ns}" --wait=false 2>/dev/null || true
    fi
  done
  for dep in $(kubectl get deploy -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "${dep}" == *-blue ]] || [[ "${dep}" == *-green ]] && continue
    kubectl scale deployment "${dep}" -n "${ns}" --replicas=0 2>/dev/null || true
  done
  sleep 2
  kubectl delete pods -n "${ns}" --all --force --grace-period=0 2>/dev/null || true
  sleep 2
}

echo "==> Heal ${PROJECT_NAME} build :${TAG} targetPort=${TARGET_PORT}"
echo "    Image: ${IMAGE}"
echo "    URL:   ${URL}"

if [[ -f "${ENV_FILE}" ]]; then
  GITHUB_TOKEN="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  export GITHUB_TOKEN
fi
AUTH_URL=""
[[ -n "${GITHUB_TOKEN:-}" ]] && AUTH_URL="https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git"

echo "==> Ensure gitops repo on main (fix detached HEAD / stuck rebase)"
gitops_ensure_on_main "${GITOPS}" main "${AUTH_URL}"

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
for k in ("activeSlot", "blue", "green", "nodeSelector"):
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
doc["resources"] = {
    "limits": {"cpu": "200m", "memory": "256Mi"},
    "requests": {"cpu": "25m", "memory": "64Mi"},
}
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"OK values: Rolling image={repo}:{tag} service.targetPort={port}")
PY

free_namespace_capacity "${NS}"

echo "==> Push GitOps to GitHub"
if ! bash "${SCRIPT_DIR}/push-gitops-lab.sh" "chore(heal): ${PROJECT_NAME} :${TAG} port ${TARGET_PORT}"; then
  echo "WARN: GitOps push failed — continuing with kubectl remediation (run: bash paas/scripts/recover-gitops-lab.sh)"
fi

free_namespace_capacity "${NS}"

echo "==> Argo sync ${APP}"
kubectl patch application "${APP}" -n argocd --type json \
  -p='[{"op": "remove", "path": "/operation"}]' 2>/dev/null || true
kubectl annotate application "${APP}" -n argocd argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
argo_sync_app_lab "${APP}" || true
argo_wait_app_lab "${APP}" 180 || true

echo "==> Force rolling deployment image + port"
for dep in $(kubectl get deploy -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${dep}" == *-blue ]] || [[ "${dep}" == *-green ]] && continue
  cname="$(kubectl get deploy "${dep}" -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].name}')"
  echo "  ${dep}: image=${IMAGE} containerPort=${TARGET_PORT}"
  kubectl set image "deployment/${dep}" -n "${NS}" "${cname}=${IMAGE}" 2>/dev/null || true
  kubectl patch deployment "${dep}" -n "${NS}" --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/replicas\",\"value\":1},{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/ports/0/containerPort\",\"value\":${TARGET_PORT}}]" 2>/dev/null || true
  env_idx="$(kubectl get deploy "${dep}" -n "${NS}" -o json | python3 -c "import json,sys;d=json.load(sys.stdin);env=d['spec']['template']['spec']['containers'][0].get('env') or [];print(next((i for i,e in enumerate(env) if e.get('name')=='PORT'),-1))" 2>/dev/null || echo -1)"
  if [[ "${env_idx}" != "-1" ]]; then
    kubectl patch deployment "${dep}" -n "${NS}" --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/${env_idx}/value\",\"value\":\"${TARGET_PORT}\"}]" 2>/dev/null || true
  fi
done

echo "==> Wait rollout"
kubectl rollout status deployment -n "${NS}" --timeout=300s 2>/dev/null || true

echo "==> Pods"
kubectl get deploy,pods -n "${NS}" -o wide 2>/dev/null || true
echo "==> Recent pod events / logs"
BAD_POD="$(kubectl get pods -n "${NS}" --field-selector=status.phase!=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "${BAD_POD}" ]]; then
  kubectl describe pod "${BAD_POD}" -n "${NS}" 2>/dev/null | tail -25 || true
  kubectl logs "${BAD_POD}" -n "${NS}" --tail=30 2>/dev/null || true
fi

HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo '?')"
echo ""
echo "HTTP ${URL} => ${HTTP}"
if [[ "${HTTP}" =~ ^[23] ]]; then
  echo "OK — open ${URL}"
else
  echo "WARN — still not HTTP 2xx/3xx"
  echo "  bash paas/scripts/recover-gitops-lab.sh"
  echo "  kubectl logs -n ${NS} -l app.kubernetes.io/instance=${APP} --tail=80"
fi
