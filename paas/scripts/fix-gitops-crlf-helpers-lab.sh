#!/usr/bin/env bash
# Repair GitOps charts: CRLF in Chart.yaml/templates caused "sanhome\r.fullname" Helm errors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"
SRC="${REPO_ROOT}/paas/gitops/apps/simple-app/templates"

[[ -d "${GITOPS}/apps" ]] || { echo "ERROR: ${GITOPS}/apps missing" >&2; exit 1; }

echo "==> Strip CR characters from all chart YAML/TPL"
find "${GITOPS}/apps" -type f \( -name '*.yaml' -o -name '*.tpl' -o -name 'Chart.yaml' \) -print0 \
  | while IFS= read -r -d '' f; do
    sed -i 's/\r//g' "$f"
  done

echo "==> Re-render blue-green templates per chart (simple-app → chart name)"
for chart_dir in "${GITOPS}"/apps/*/templates; do
  [[ -d "${chart_dir}" ]] || continue
  app_dir="$(dirname "${chart_dir}")"
  cname=""
  if [[ -f "${app_dir}/Chart.yaml" ]]; then
    cname="$(grep -E '^name:' "${app_dir}/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '\r"' | xargs)"
  fi
  [[ -n "${cname}" ]] || cname="$(basename "${app_dir}")"
  if [[ ! -f "${chart_dir}/_helpers.tpl" ]]; then
    echo "WARN: skip ${app_dir} — no _helpers.tpl" >&2
    continue
  fi
  for rel in deployment-bluegreen.yaml deployment.yaml service.yaml; do
    sed "s/simple-app/${cname}/g" "${SRC}/${rel}" | tr -d '\r' > "${chart_dir}/${rel}"
  done
  echo "  OK ${cname}"
done

echo ""
echo "==> Verify sanhome (must not error)"
helm template paas-sanhome "${GITOPS}/apps/sanhome" -f "${GITOPS}/apps/sanhome/values.yaml" >/dev/null
echo "OK: helm template paas-sanhome"
grep 'include' "${GITOPS}/apps/sanhome/templates/service.yaml" | head -3

echo ""
echo "==> Git commit + push"
cd "${GITOPS}"
git add apps/
if git diff --cached --quiet; then
  echo "WARN: no git changes — templates may already be fixed locally"
else
  git commit -m "fix(gitops): remove CRLF from chart templates (sanhome.fullname)"
fi
bash "${SCRIPT_DIR}/push-gitops-lab.sh" || {
  tok="$(grep -E '^GITOPS_REPO_TOKEN=' "${REPO_ROOT}/paas/frontend/docker-compose.env" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs)"
  git push "https://${tok}@github.com/nourhb/gitops.git" main
}

echo ""
echo "==> Argo sync paas-sanhome"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"
kubectl patch application paas-sanhome -n argocd --type json \
  -p='[{"op":"remove","path":"/operation"}]' 2>/dev/null || true
kubectl annotate application paas-sanhome -n argocd argocd.argoproj.io/refresh=hard --overwrite
sleep 3
argo_sync_app_lab paas-sanhome
argo_wait_app_lab paas-sanhome 300 || true

kubectl get deploy,pods -n sanhome 2>/dev/null || true
HTTP="$(curl -s -o /dev/null -w '%{http_code}' http://sanhome.192.168.56.129.nip.io:30659/ 2>/dev/null || echo '?')"
echo "HTTP sanhome: ${HTTP}"
