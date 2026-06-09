#!/usr/bin/env bash
# Copy blue-green Helm templates into every project chart under ~/gitops.
# Rewrites simple-app → chart name so templates match each chart's _helpers.tpl (sanhome.fullname, etc.).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"
SRC="${REPO_ROOT}/paas/gitops/apps/simple-app/templates"

[[ -d "${GITOPS}/apps" ]] || { echo "ERROR: ${GITOPS}/apps missing" >&2; exit 1; }

chart_name_for() {
  local app_dir="$1"
  local name=""
  if [[ -f "${app_dir}/Chart.yaml" ]]; then
    name="$(grep -E '^name:' "${app_dir}/Chart.yaml" | head -1 | awk '{print $2}' | tr -d '\r"' | xargs)"
  fi
  if [[ -z "${name}" ]]; then
    name="$(basename "${app_dir}")"
  fi
  printf '%s' "${name}"
}

for chart in "${GITOPS}"/apps/*/templates; do
  [[ -d "${chart}" ]] || continue
  app_dir="$(dirname "${chart}")"
  cname="$(chart_name_for "${app_dir}")"
  if [[ ! -f "${app_dir}/templates/_helpers.tpl" ]]; then
    echo "WARN: skip ${app_dir} — missing templates/_helpers.tpl (bootstrap chart first)" >&2
    continue
  fi
  if ! grep -q "define \"${cname}.fullname\"" "${app_dir}/templates/_helpers.tpl" 2>/dev/null; then
    echo "WARN: ${app_dir}/_helpers.tpl missing define \"${cname}.fullname\" — check Chart.yaml name" >&2
  fi
  for rel in deployment-bluegreen.yaml deployment.yaml service.yaml; do
    sed "s/simple-app/${cname}/g" "${SRC}/${rel}" > "${chart}/${rel}"
  done
  echo "updated ${chart} (simple-app → ${cname})"
done

echo ""
echo "Verify one chart, e.g. sanhome:"
echo "  helm template paas-sanhome ${GITOPS}/apps/sanhome -f ${GITOPS}/apps/sanhome/values.yaml | grep -E '^  name:'"
echo ""
echo "Commit + push:"
echo "  bash ${SCRIPT_DIR}/push-gitops-lab.sh 'fix(gitops): blue-green templates use per-chart helper names'"
