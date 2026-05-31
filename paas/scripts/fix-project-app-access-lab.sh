#!/usr/bin/env bash
# Repair GitOps ingress + values for a deployed PaaS project (fixes nip.io 404).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="${1:-}"
if [[ -z "${PROJECT_NAME}" ]]; then
  echo "Usage: bash paas/scripts/fix-project-app-access-lab.sh <project-name>" >&2
  echo "Example: bash paas/scripts/fix-project-app-access-lab.sh sanhome" >&2
  exit 1
fi

NODE_IP="${NODE_IP:-192.168.56.129}"
INGRESS_PORT="${APPS_PUBLIC_INGRESS_HTTP_PORT:-30659}"
GITOPS="${GITOPS:-${HOME}/gitops}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/frontend/docker-compose.env}"
INGRESS_CLASS="${APPS_INGRESS_CLASS:-traefik}"
if [[ -f "${ENV_FILE}" ]]; then
  val="$(grep -E '^APPS_INGRESS_CLASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '\r"' | xargs || true)"
  [[ -n "${val}" ]] && INGRESS_CLASS="${val}"
fi
if [[ -f "${ENV_FILE}" && -z "${GITHUB_TOKEN:-}" ]]; then
  tok="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -n "${tok}" ]] && export GITHUB_TOKEN="${tok}"
fi
CANONICAL_URL="http://${PROJECT_NAME}.${NODE_IP}.nip.io:${INGRESS_PORT}/"
CHART_DIR="${GITOPS}/apps/${PROJECT_NAME}"
VALUES="${CHART_DIR}/values.yaml"
REF_CHART="${ROOT}/gitops/apps/simple-app"
[[ -d "${REF_CHART}" ]] || REF_CHART="${GITOPS}/apps/simple-app"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -d "${GITOPS}/.git" ]] || die "Clone gitops first: git clone https://github.com/nourhb/gitops.git ${GITOPS}"
[[ -d "${REF_CHART}" ]] || die "Missing chart reference at ${REF_CHART}"

echo "==> Refresh Helm chart templates from ${REF_CHART} → apps/${PROJECT_NAME}"
mkdir -p "${CHART_DIR}/templates"
for f in Chart.yaml templates/_helpers.tpl templates/deployment.yaml templates/service.yaml templates/ingress.yaml; do
  src="${REF_CHART}/${f}"
  dest="${CHART_DIR}/${f}"
  [[ -f "${src}" ]] || continue
  sed "s/simple-app/${PROJECT_NAME}/g" "${src}" > "${dest}"
done

python3 - "${VALUES}" "${PROJECT_NAME}" "${NODE_IP}" "${INGRESS_CLASS}" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("Install PyYAML: pip3 install pyyaml\n")
    raise

values_path, project_name, node_ip, ingress_class = sys.argv[1:5]
path = Path(values_path)
doc = {}
if path.exists():
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    if isinstance(loaded, dict):
        doc = loaded

image = doc.get("image") if isinstance(doc.get("image"), dict) else {}
if not image.get("repository"):
    image["repository"] = f"{node_ip}:30002/paas/{project_name}"
if not image.get("tag"):
    image["tag"] = "latest"
if not image.get("pullPolicy"):
    image["pullPolicy"] = "IfNotPresent"
doc["image"] = image

doc.setdefault("imagePullSecrets", [{"name": "harbor-regcred"}])
doc.pop("nodeSelector", None)
service = doc.get("service") if isinstance(doc.get("service"), dict) else {}
service.setdefault("targetPort", 3000)
doc["service"] = service

resources = doc.get("resources") if isinstance(doc.get("resources"), dict) else {}
limits = resources.get("limits") if isinstance(resources.get("limits"), dict) else {}
requests = resources.get("requests") if isinstance(resources.get("requests"), dict) else {}
limits.setdefault("cpu", "500m")
limits.setdefault("memory", "768Mi")
requests.setdefault("cpu", "100m")
requests.setdefault("memory", "256Mi")
resources["limits"] = limits
resources["requests"] = requests
doc["resources"] = resources
doc.setdefault("env", [])

ingress = doc.get("ingress") if isinstance(doc.get("ingress"), dict) else {}
ingress["enabled"] = True
ingress["className"] = ingress_class
ingress["hosts"] = [{"host": f"{project_name}.{node_ip}.nip.io"}]
ingress.setdefault("tls", [])
doc["ingress"] = ingress

path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False), encoding="utf-8")
print(f"Patched {path}")
PY

echo "==> Commit + push gitops"
pushd "${GITOPS}" >/dev/null
git add "apps/${PROJECT_NAME}"
git diff --cached --quiet && echo "No gitops changes" || {
  git commit -m "fix(gitops): enable ingress for ${PROJECT_NAME} lab access"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
  else
    echo "WARN: set GITHUB_TOKEN and run: git push origin main"
  fi
}
popd >/dev/null

APP_NAME="${ARGOCD_APP_PREFIX}-${PROJECT_NAME}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"

echo "==> Argo CD sync ${APP_NAME} (kubectl — ignores expired argocd CLI token)"
if kubectl get application "${APP_NAME}" -n argocd >/dev/null 2>&1; then
  argo_sync_app_lab "${APP_NAME}" || true
  argo_wait_app_lab "${APP_NAME}" 300 || true
else
  echo "WARN: Argo application ${APP_NAME} not found — create project in PaaS or check ARGOCD_APP_PREFIX"
fi

echo "==> Verify ingress + HTTP"
kubectl get ingress -A 2>/dev/null | grep -i "${PROJECT_NAME}" || echo "WARN: no ingress yet for ${PROJECT_NAME}"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${CANONICAL_URL}" 2>/dev/null || echo 000)"
echo "Open: ${CANONICAL_URL}"
echo "HTTP ${HTTP}"
if [[ "${HTTP}" == "404" ]]; then
  echo "Still 404 — check: kubectl get pods -n ${PROJECT_NAME}; kubectl describe ingress -n ${PROJECT_NAME}"
  exit 1
fi
echo "OK"
