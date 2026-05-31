#!/usr/bin/env bash
# Fix ingress.className in nourhb/gitops (Argo selfHeal reverts kubectl-only patches).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT/frontend/docker-compose.env}"
GITOPS="${GITOPS:-${HOME}/gitops}"
GITOPS_REMOTE="${GITOPS_REMOTE:-https://github.com/nourhb/gitops.git}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
INGRESS_CLASS="${APPS_INGRESS_CLASS:-traefik}"

if [[ -f "${ENV_FILE}" ]]; then
  val="$(grep -E '^APPS_INGRESS_CLASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | sed 's/[[:space:]]*#.*//' | tr -d '\r"' | xargs || true)"
  [[ -n "${val}" ]] && INGRESS_CLASS="${val}"
  if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    tok="$(grep -E '^GITOPS_REPO_TOKEN=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    [[ -n "${tok}" ]] && export GITHUB_TOKEN="${tok}"
  fi
fi

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${GITHUB_TOKEN:-}" ]] || die "Set GITHUB_TOKEN or GITOPS_REPO_TOKEN in ${ENV_FILE}"

if [[ ! -d "${GITOPS}/.git" ]]; then
  echo "==> Cloning ${GITOPS_REMOTE} → ${GITOPS}"
  git clone "${GITOPS_REMOTE}" "${GITOPS}"
fi

pushd "${GITOPS}" >/dev/null
if [[ -d .git/rebase-merge || -d .git/rebase-apply ]]; then
  git rebase --abort 2>/dev/null || true
fi
git fetch "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
git checkout main 2>/dev/null || git checkout -B main
git reset --hard FETCH_HEAD
popd >/dev/null

REF_CHART="${GITOPS}/apps/simple-app"
[[ -d "${REF_CHART}" ]] || die "Missing ${REF_CHART} in gitops repo"

NODE_IP="${NODE_IP:-192.168.56.129}"
echo "==> Ensure GitOps chart dirs exist for Argo CD ${ARGOCD_APP_PREFIX}-* apps"
while IFS= read -r app; do
  [[ -z "${app}" ]] && continue
  proj="${app#${ARGOCD_APP_PREFIX}-}"
  app_dir="${GITOPS}/apps/${proj}"
  mkdir -p "${app_dir}"
  if [[ ! -f "${app_dir}/values.yaml" ]]; then
    cat > "${app_dir}/values.yaml" <<EOF
image:
  repository: ${NODE_IP}:30002/paas/${proj}
  tag: latest
  pullPolicy: IfNotPresent
imagePullSecrets:
  - name: harbor-regcred
nodeSelector:
  kubernetes.io/hostname: master
service:
  targetPort: 3000
ingress:
  enabled: true
  className: ${INGRESS_CLASS}
  hosts:
    - host: ${proj}.${NODE_IP}.nip.io
  tls: []
EOF
    echo "  created stub values for ${proj}"
  fi
done < <(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep "^${ARGOCD_APP_PREFIX}-" || true)

echo "==> Force ingress.className=${INGRESS_CLASS} in apps/*/values.yaml (+ bootstrap missing charts)"
python3 - "${GITOPS}" "${INGRESS_CLASS}" <<'PY'
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("Install PyYAML: pip3 install pyyaml\n")
    raise

gitops_root = Path(sys.argv[1])
ingress_class = sys.argv[2]
ref_chart = gitops_root / "apps" / "simple-app"
apps_root = gitops_root / "apps"
changed = []

def bootstrap_chart(app_dir: Path, app_name: str) -> None:
    needs = not (app_dir / "Chart.yaml").exists() or not (app_dir / "templates" / "deployment.yaml").exists()
    if not needs:
        return
    app_dir.mkdir(parents=True, exist_ok=True)
    (app_dir / "templates").mkdir(exist_ok=True)
    for rel in [
        "Chart.yaml",
        "templates/_helpers.tpl",
        "templates/deployment.yaml",
        "templates/service.yaml",
        "templates/ingress.yaml",
    ]:
        src = ref_chart / rel
        if not src.exists():
            continue
        text = src.read_text(encoding="utf-8").replace("simple-app", app_name)
        (app_dir / rel).write_text(text, encoding="utf-8")
    changed.append(f"bootstrapped chart {app_dir.relative_to(gitops_root)}")

for values_path in sorted(apps_root.glob("*/values.yaml")):
    app_name = values_path.parent.name
    bootstrap_chart(values_path.parent, app_name)
    doc = yaml.safe_load(values_path.read_text(encoding="utf-8")) or {}
    if not isinstance(doc, dict):
        continue
    ingress = doc.get("ingress") if isinstance(doc.get("ingress"), dict) else {}
    before = ingress.get("className")
    ingress["enabled"] = True
    ingress["className"] = ingress_class
    if not ingress.get("hosts"):
        node_ip = "192.168.56.129"
        ingress["hosts"] = [{"host": f"{app_name}.{node_ip}.nip.io"}]
    ingress.setdefault("tls", [])
    doc["ingress"] = ingress
    doc.setdefault("imagePullSecrets", [{"name": "harbor-regcred"}])
    new_text = yaml.safe_dump(doc, default_flow_style=False, sort_keys=False)
    old_text = values_path.read_text(encoding="utf-8")
    if new_text != old_text or before != ingress_class:
        values_path.write_text(new_text, encoding="utf-8")
        changed.append(f"{values_path.relative_to(gitops_root)} ({before!s} -> {ingress_class})")

print(f"Updated {len(changed)} path(s)")
for line in changed:
    print(f"  {line}")
if not changed:
    print("  (no changes needed)")
PY

pushd "${GITOPS}" >/dev/null
git add apps/
if git diff --cached --quiet; then
  echo "==> GitOps already has ingress.className=${INGRESS_CLASS} everywhere"
else
  git commit -m "fix(gitops): set ingress.className=${INGRESS_CLASS} for lab Traefik :30659"
  git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
  echo "==> Pushed to gitops main"
fi
popd >/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
argo_load_lab_env "${ROOT}"

echo "==> Argo CD sync all ${ARGOCD_APP_PREFIX}-* applications (kubectl — ignores expired argocd CLI token)"
synced=0
while IFS= read -r app; do
  [[ -z "${app}" ]] && continue
  echo "  sync ${app}"
  argo_sync_app_lab "${app}" || echo "WARN: could not trigger sync for ${app}" >&2
  synced=$((synced + 1))
done < <(kubectl get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep "^${ARGOCD_APP_PREFIX}-" || true)

echo "==> Waiting for apps to reconcile (up to 120s each for sanhome + profit-margin)…"
for app in paas-sanhome paas-profit-margin-sponsoring-facebook; do
  if kubectl get application "${app}" -n argocd >/dev/null 2>&1; then
    argo_wait_app_lab "${app}" 120 || true
  fi
done
sleep 5

echo "==> Ingress classes now:"
kubectl get ingress -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CLASS:.spec.ingressClassName' 2>/dev/null | grep -v '^paas' || true

echo ""
echo "Probe sanhome:"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --connect-timeout 15 \
  "http://sanhome.192.168.56.129.nip.io:${APPS_PUBLIC_INGRESS_HTTP_PORT:-30659}/" || echo "HTTP 000"
