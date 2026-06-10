#!/usr/bin/env bash
# Emergency heal for lab demo apps — works without git pull (nginx conf + python gunicorn fix).
# Usage: bash paas/scripts/heal-lab-apps-emergency.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/patch-nginx-deploy-lab.sh
source "${SCRIPT_DIR}/lib/patch-nginx-deploy-lab.sh"
# shellcheck source=lib/patch-python-deploy-lab.sh
source "${SCRIPT_DIR}/lib/patch-python-deploy-lab.sh"
# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"

heal_one() {
  local project="$1"
  local port="$2"
  local ns="${project}"
  local app="paas-${project}"

  echo ""
  echo "=== ${project} (port ${port}) ==="
  for dep in $(kubectl get deploy -n "${ns}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    [[ "${dep}" == *-blue ]] || [[ "${dep}" == *-green ]] && continue
    kubectl scale deployment "${dep}" -n "${ns}" --replicas=1 2>/dev/null || true
  done

  if [[ "${port}" == "80" ]]; then
    patch_nginx_deploy_lab "${ns}"
  fi
  if [[ "${port}" == "8000" ]]; then
    patch_python_deploy_lab "${ns}" "${port}"
  fi

  argo_sync_app_lab "${app}" 2>/dev/null || true
  kubectl rollout status deployment -n "${ns}" --timeout=90s 2>/dev/null || true
  kubectl get pods -n "${ns}" -o wide 2>/dev/null || true
  kubectl logs -n "${ns}" -l "app.kubernetes.io/instance=${app}" --tail=15 2>/dev/null || true
  curl -s -o /dev/null -w "HTTP %{http_code}\n" "http://${project}.192.168.56.129.nip.io:30659/" 2>/dev/null || true
}

heal_one demo-angular-app 80
heal_one angular-docker 80
heal_one docker-demo-with-simple-python-app 8000

echo ""
echo "Done."
