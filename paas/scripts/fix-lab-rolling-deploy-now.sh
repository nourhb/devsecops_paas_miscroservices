#!/usr/bin/env bash
# One-shot: stop BlueGreen deploy failures — use Rolling + sync Argo apps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"

ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
GITOPS="${GITOPS:-${HOME}/gitops}"
PAAS_NS="${PAAS_NAMESPACE:-paas}"

echo "==> Set PAAS_DEPLOYMENT_STRATEGY=Rolling on PaaS frontend"
if [[ -f "${SCRIPT_DIR}/set-lab-env-key.sh" ]]; then
  bash "${SCRIPT_DIR}/set-lab-env-key.sh" PAAS_DEPLOYMENT_STRATEGY Rolling sync || true
else
  echo "WARN: set-lab-env-key.sh missing — set PAAS_DEPLOYMENT_STRATEGY=Rolling manually in frontend env"
fi

echo "==> Patch GitOps values.yaml → Rolling + default targetPort"
python3 - <<'PY'
import pathlib, yaml, sys

def guess_port(name: str) -> int:
    n = name.lower()
    if "angular" in n:
        return 80
    if "python" in n or "docker-demo" in n:
        return 8000
    return 3000

root = pathlib.Path(__import__("os").environ.get("GITOPS", str(pathlib.Path.home() / "gitops")))
apps = root / "apps"
if not apps.is_dir():
    print(f"WARN: {apps} not found — skip values patch", file=sys.stderr)
    sys.exit(0)
for values in apps.glob("*/values.yaml"):
    try:
        doc = yaml.safe_load(values.read_text()) or {}
    except Exception as e:
        print(f"WARN: skip {values}: {e}", file=sys.stderr)
        continue
    if not isinstance(doc, dict):
        continue
    project = values.parent.name
    doc["deploymentStrategy"] = "Rolling"
    for k in ("activeSlot", "blue", "green"):
        doc.pop(k, None)
    svc = doc.get("service") if isinstance(doc.get("service"), dict) else {}
    if not svc.get("targetPort"):
        svc["targetPort"] = guess_port(project)
    doc["service"] = svc
    values.write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False))
    print(f"OK: {values} → Rolling targetPort={svc.get('targetPort')}")
PY

echo "==> Push GitOps to GitHub (required — Argo reads remote, not only ~/gitops)"
if [[ -f "${SCRIPT_DIR}/push-gitops-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/push-gitops-lab.sh" "chore: lab rolling deploy strategy + targetPort"
else
  echo "ERROR: push-gitops-lab.sh missing" >&2
  exit 1
fi

echo "==> Redeploy PaaS frontend (embeds deploy fallback fix)"
bash "${SCRIPT_DIR}/deploy-paas-frontend-k8s.sh"

echo "==> Sync all ${ARGOCD_APP_PREFIX}-* Argo applications"
while IFS= read -r app; do
  [[ -n "${app}" ]] || continue
  echo "  sync ${app}"
  argo_sync_app_lab "${app}" || true
done < <(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep "^${ARGOCD_APP_PREFIX}-" || true)

echo ""
echo "Done. Re-trigger Deploy from the PaaS UI for your project."
