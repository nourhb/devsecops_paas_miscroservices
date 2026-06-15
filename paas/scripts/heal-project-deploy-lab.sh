#!/usr/bin/env bash
set -uo pipefail
PROJECT_NAME="${1:?usage: heal-project-deploy-lab.sh <projectName> <jenkinsBuildNumber> [80|8000|3000]}"
TAG="${2:?usage: heal-project-deploy-lab.sh <projectName> <jenkinsBuildNumber>}"
TARGET_PORT="${3:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"
NS="${PROJECT_NAME}"
APP="${ARGOCD_APP_PREFIX}-${PROJECT_NAME}"
IMAGE="${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_NAME}:${TAG}"
URL="http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"
# shellcheck source=gitops-lab-lib.sh
source "${SCRIPT_DIR}/gitops-lab-lib.sh"
argo_sync_app_kubectl() {
  local app="$1"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  [[ -n "${app}" ]] || return 1
  if ! kubectl get application "${app}" -n "${ns}" >/dev/null 2>&1; then
    echo "WARN: Application ${app} not found in ${ns}" >&2
    return 1
  fi
  kubectl annotate application "${app}" -n "${ns}" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  if kubectl patch application "${app}" -n "${ns}" --type merge -p '{
    "operation": {
      "initiatedBy": {"username": "lab-fix"},
      "sync": {
        "revision": "HEAD",
        "prune": false,
        "syncStrategy": {"apply": {"force": true}}
      }
    }
  }' >/dev/null 2>&1; then
    echo "OK: kubectl sync triggered for ${app}"
    return 0
  fi
  echo "WARN: kubectl patch sync failed for ${app}" >&2
  return 1
}
argo_sync_app_cli() {
  local app="$1"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  command -v argocd >/dev/null 2>&1 || return 1
  local base="${ARGOCD_BASE_URL:-}"
  local user="${ARGOCD_USERNAME:-admin}"
  local pass="${ARGOCD_PASSWORD:-}"
  [[ -n "${base}" && -n "${pass}" ]] || return 1
  local host port scheme
  if [[ "${base}" =~ ^https?://([^:/]+):?([0-9]*) ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
    scheme="http"
    [[ "${base}" == https* ]] && scheme="https"
  else
    return 1
  fi
  local login_args=(--username "${user}" --password "${pass}" --insecure --grpc-web)
  [[ -n "${port}" ]] && login_args+=(--port "${port}") || true
  argocd login "${host}" "${login_args[@]}" >/dev/null 2>&1 || return 1
  argocd app sync "${app}" --force >/dev/null 2>&1 && {
    echo "OK: argocd CLI sync for ${app}"
    return 0
  }
  return 1
}
argo_sync_app_lab() {
  local app="$1"
  argo_sync_app_kubectl "${app}" && return 0
  argo_sync_app_cli "${app}" && return 0
  return 1
}
argo_wait_sync_lab() {
  local app="$1"
  local timeout="${2:-45}"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  local deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    local health sync
    health="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "")"
    sync="$(kubectl get application "${app}" -n "${ns}" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "")"
    if [[ "${sync}" == "Synced" ]]; then
      echo "OK: ${app} Synced (health=${health:-?})"
      return 0
    fi
    sleep 3
  done
  echo "WARN: ${app} not Synced within ${timeout}s" >&2
  return 1
}
argo_diagnose_app_lab() {
  local app="$1"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  echo "==> Argo diagnose ${app}"
  kubectl get application "${app}" -n "${ns}" -o jsonpath='sync={.status.sync.status} health={.status.health.status} rev={.status.sync.revision}{"\n"}' 2>/dev/null || true
  kubectl get application "${app}" -n "${ns}" -o jsonpath='{range .status.conditions[*]}{.type}={.message}{"\n"}{end}' 2>/dev/null | tail -5 || true
  kubectl get application "${app}" -n "${ns}" -o jsonpath='{range .status.operationState.syncResult.resources[?(@.message)]}{.kind}/{.namespace}/{.name}: {.message}{"\n"}{end}' 2>/dev/null | tail -10 || true
}
argo_sync_app_kubectl_revision() {
  local app="$1"
  local revision="$2"
  local ns="${ARGOCD_NAMESPACE:-argocd}"
  [[ -n "${app}" && -n "${revision}" ]] || return 1
  kubectl annotate application "${app}" -n "${ns}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  kubectl patch application "${app}" -n "${ns}" --type merge -p "{
    \"operation\": {
      \"initiatedBy\": {\"username\": \"lab-fix\"},
      \"sync\": {
        \"revision\": \"${revision}\",
        \"prune\": true,
        \"syncStrategy\": {\"apply\": {\"force\": true}}
      }
    }
  }" >/dev/null 2>&1 && {
    echo "OK: kubectl sync ${app} @ ${revision:0:12}"
    return 0
  }
  return 1
}
helm_apply_chart_lab() {
  local ns="$1"
  local chart_dir="$2"
  local release="$3"
  command -v helm >/dev/null 2>&1 || return 1
  [[ -d "${chart_dir}" ]] || return 1
  echo "==> helm template ${release} + kubectl apply (Argo fallback)"
  helm template "${release}" "${chart_dir}" --namespace "${ns}" | kubectl apply -n "${ns}" -f - 2>/dev/null && return 0
  return 1
}
patch_nginx_deploy_lab() {
  local ns="$1"
  local cm="paas-nginx-override"
  [[ -n "${ns}" ]] || return 1
  kubectl create configmap "${cm}" -n "${ns}" --dry-run=client -o yaml \
    --from-literal=default.conf='server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}' | kubectl apply -f - >/dev/null
  python3 - "${ns}" "${cm}" <<'PY'
import json, subprocess, sys
ns, cm = sys.argv[1:3]
out = subprocess.check_output(
    ["kubectl", "get", "deploy", "-n", ns, "-o", "json"], text=True
)
data = json.loads(out)
for dep in data.get("items", []):
    name = dep.get("metadata", {}).get("name", "")
    if name.endswith("-blue") or name.endswith("-green"):
        continue
    spec = dep.setdefault("spec", {}).setdefault("template", {}).setdefault("spec", {})
    volumes = spec.setdefault("volumes", [])
    if not any(v.get("name") == "paas-nginx-conf" for v in volumes):
        volumes.append({"name": "paas-nginx-conf", "configMap": {"name": cm}})
    containers = spec.get("containers") or []
    if not containers:
        continue
    mounts = containers[0].setdefault("volumeMounts", [])
    if not any(m.get("name") == "paas-nginx-conf" for m in mounts):
        mounts.append({
            "name": "paas-nginx-conf",
            "mountPath": "/etc/nginx/conf.d/default.conf",
            "subPath": "default.conf",
        })
    containers[0]["command"] = ["nginx"]
    containers[0]["args"] = ["-g", "daemon off;"]
    patch = json.dumps({"spec": dep["spec"]})
    subprocess.run(
        ["kubectl", "patch", "deployment", name, "-n", ns, "--type", "merge", "-p", patch],
        check=False,
    )
    print(f"  nginx override mounted on deployment/{name}")
PY
}
patch_python_deploy_lab() {
  local ns="$1"
  local port="${2:-8000}"
  [[ -n "${ns}" ]] || return 1
  python3 - "${ns}" "${port}" <<'PY'
import json, subprocess, sys
ns, port = sys.argv[1:3]
start = (
    "pip install -q --root-user-action=ignore 'gunicorn>=22' 'flask>=2' 2>/dev/null || true; "
    "cd /app && exec python3 -m gunicorn -b 0.0.0.0:" + port + " main:app"
)
out = subprocess.check_output(["kubectl", "get", "deploy", "-n", ns, "-o", "json"], text=True)
data = json.loads(out)
for dep in data.get("items", []):
    name = dep.get("metadata", {}).get("name", "")
    if name.endswith("-blue") or name.endswith("-green"):
        continue
    containers = dep.get("spec", {}).get("template", {}).get("spec", {}).get("containers") or []
    if not containers:
        continue
    containers[0]["command"] = ["/bin/sh", "-c"]
    containers[0]["args"] = [start]
    patch = json.dumps({"spec": dep["spec"]})
    subprocess.run(
        ["kubectl", "patch", "deployment", name, "-n", ns, "--type", "merge", "-p", patch],
        check=False,
    )
    print(f"  python start override on deployment/{name}")
PY
}
ARGO_WAIT_SECONDS="${ARGO_WAIT_SECONDS:-120}"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-120s}"
if [[ -z "${TARGET_PORT}" ]]; then
  case "${PROJECT_NAME}" in
    *angular*|*demo-angular*) TARGET_PORT=80 ;;
    *python*|docker-demo*) TARGET_PORT=8000 ;;
    *) TARGET_PORT=3000 ;;
  esac
fi
[[ -d "${GITOPS}/.git" ]] || { echo "ERROR: clone gitops to ${GITOPS}" >&2; exit 1; }
if [[ ! -f "${VALUES}" ]] || gitops_file_has_conflicts "${VALUES}"; then
  echo "==> Missing or conflicted ${VALUES} — bootstrap chart from repo"
  bash "${SCRIPT_DIR}/repair-gitops-app-lab.sh" "${PROJECT_NAME}" "${TAG}" || exit 1
elif pushd "${GITOPS}" >/dev/null && [[ -n "$(git diff --name-only --diff-filter=U 2>/dev/null || true)" ]]; then
  popd >/dev/null
  echo "==> GitOps repo has unresolved merge conflicts — full repair"
  bash "${SCRIPT_DIR}/repair-gitops-app-lab.sh" "${PROJECT_NAME}" "${TAG}" || exit 1
else
  popd >/dev/null 2>/dev/null || true
fi
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }
ensure_harbor_regcred() {
  local ns="$1"
  local user pass
  user="${HARBOR_USER:-admin}"
  pass="${HARBOR_PASS:-Harbor12345}"
  if [[ -f "${ENV_FILE}" ]]; then
    user="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    pass="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    [[ -z "${user}" ]] && user="admin"
    [[ -z "${pass}" ]] && pass="Harbor12345"
  fi
  kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1 || true
  kubectl create secret docker-registry harbor-regcred -n "${ns}" \
    --docker-server="${HARBOR_HOST}:${HARBOR_PORT}" \
    --docker-username="${user}" \
    --docker-password="${pass}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "OK: harbor-regcred in namespace ${ns} (${HARBOR_HOST}:${HARBOR_PORT})"
}
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
ensure_harbor_regcred "${NS}"
echo "==> Patch ${VALUES} (Rolling + image + targetPort)"
python3 - "${VALUES}" "${TAG}" "${NODE_IP}" "${PROJECT_NAME}" "${TARGET_PORT}" "${HARBOR_PORT}" <<'PY'
import sys
from pathlib import Path
import yaml
path, tag, node_ip, name, port, harbor_port = sys.argv[1:7]
port = int(port)
repo = f"harbor.{node_ip}.nip.io:{harbor_port}/paas/{name}"
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
doc["nameOverride"] = name
doc["fullnameOverride"] = f"paas-{name}"
svc = doc.get("service") if isinstance(doc.get("service"), dict) else {}
svc["targetPort"] = port
doc["service"] = svc
if not doc.get("imagePullSecrets"):
    doc["imagePullSecrets"] = [{"name": "harbor-regcred"}]
doc["resources"] = {
    "limits": {"cpu": "200m", "memory": "256Mi"},
    "requests": {"cpu": "25m", "memory": "64Mi"},
}
if port == 8000:
    doc["probes"] = {
        "readiness": {"initialDelaySeconds": 30, "periodSeconds": 10, "failureThreshold": 12},
        "liveness": {"initialDelaySeconds": 90, "periodSeconds": 20, "failureThreshold": 6},
    }
elif port == 80:
    doc["probes"] = {
        "type": "tcp",
        "readiness": {"initialDelaySeconds": 3, "periodSeconds": 5, "failureThreshold": 6},
        "liveness": {"initialDelaySeconds": 10, "periodSeconds": 15, "failureThreshold": 6},
    }
Path(path).write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"OK values: Rolling image={repo}:{tag} service.targetPort={port}")
PY
free_namespace_capacity "${NS}"
echo "==> Push GitOps to GitHub"
if ! bash "${SCRIPT_DIR}/push-gitops-lab.sh" "chore(heal): ${PROJECT_NAME} :${TAG} port ${TARGET_PORT}"; then
  echo "WARN: GitOps push failed — continuing with kubectl remediation (run: bash paas/scripts/push-gitops-lab.sh)"
fi
bash "${SCRIPT_DIR}/ensure-harbor-nipio-cosign-lab.sh" "${PROJECT_NAME}" "${TAG}" || true
free_namespace_capacity "${NS}"
GITOPS_REV="$(git -C "${GITOPS}" rev-parse HEAD 2>/dev/null || echo HEAD)"
echo "==> Argo sync ${APP} @ ${GITOPS_REV:0:12}"
kubectl patch application "${APP}" -n argocd --type json \
  -p='[{"op": "remove", "path": "/operation"}]' 2>/dev/null || true
argo_sync_app_kubectl_revision "${APP}" "${GITOPS_REV}" || argo_sync_app_lab "${APP}" || true
argo_wait_sync_lab "${APP}" "${ARGO_WAIT_SECONDS}" || {
  argo_diagnose_app_lab "${APP}"
  helm_apply_chart_lab "${NS}" "${GITOPS}/apps/${PROJECT_NAME}" "paas-${PROJECT_NAME}" || true
}
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
  if [[ "${TARGET_PORT}" == "8000" ]]; then
    kubectl patch deployment "${dep}" -n "${NS}" --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":30},{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":12},{"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds","value":90}]' 2>/dev/null || true
  fi
done
if [[ "${TARGET_PORT}" == "80" ]]; then
  echo "==> Nginx config override (fixes invalid repo nginx.conf in existing images)"
  patch_nginx_deploy_lab "${NS}" || true
fi
if [[ "${TARGET_PORT}" == "8000" ]]; then
  echo "==> Python start override (gunicorn>=22 for Python 3.12)"
  patch_python_deploy_lab "${NS}" "${TARGET_PORT}" || true
fi
echo "==> Wait rollout"
kubectl rollout status deployment -n "${NS}" --timeout="${ROLLOUT_TIMEOUT}" 2>/dev/null || true
echo "==> Pods"
kubectl get deploy,pods -n "${NS}" -o wide 2>/dev/null || true
echo "==> Recent pod events / logs"
kubectl logs -n "${NS}" -l "app.kubernetes.io/instance=${APP}" --tail=40 2>/dev/null || true
BAD_POD="$(kubectl get pods -n "${NS}" -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -1 || true)"
if [[ -n "${BAD_POD}" ]]; then
  kubectl describe pod "${BAD_POD}" -n "${NS}" 2>/dev/null | tail -20 || true
fi
HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo '?')"
echo ""
echo "HTTP ${URL} => ${HTTP}"
if [[ "${HTTP}" =~ ^[23] ]]; then
  echo "OK — open ${URL}"
else
  echo "WARN — still not HTTP 2xx/3xx"
  echo "  bash paas/scripts/push-gitops-lab.sh"
  echo "  kubectl logs -n ${NS} -l app.kubernetes.io/instance=${APP} --tail=80"
fi
