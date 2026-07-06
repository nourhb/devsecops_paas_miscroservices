#!/usr/bin/env bash
# Lab script to data persist on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
LAB_VALUES="${REPO_ROOT}/paas/k8s-manifests/lab"

log() { echo "[data-persist] $*"; }

bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" 2>/dev/null || true

log "1/5 Retain annotations on existing PVCs"
bash "${SCRIPT_DIR}/lab-pvc-retain.sh" guard

log "2/5 Postgres — PVC postgres-pvc (users, projects, login)"
kubectl apply -f "${LAB_VALUES}/postgres-in-paas.yaml" 2>/dev/null || true

log "3/5 SonarQube — enable PVC (tokens, projects survive restart)"
if [[ -f "${SCRIPT_DIR}/lab-sonarqube-fix-now.sh" ]]; then
  bash "${SCRIPT_DIR}/lab-sonarqube-fix-now.sh" 2>/dev/null \
    || log "WARN: Sonar helm skipped — run when API stable: bash paas/scripts/lab.sh sonarqube-fix"
fi

log "4/5 Dependency-Track — PVC for API"
if command -v helm >/dev/null 2>&1 && helm repo list 2>/dev/null | grep -q dependency-track; then
  DT_VALUES="${LAB_VALUES}/dependency-track-helm-lab-values.yaml"
  if [[ -f "${DT_VALUES}" ]] && kubectl get ns dependency-track >/dev/null 2>&1; then
    helm upgrade dtrack dependency-track/dependency-track -n dependency-track \
      -f "${DT_VALUES}" --reuse-values --timeout 15m 2>/dev/null \
      || log "WARN: DT helm upgrade skipped"
  fi
fi

log "5/5 Harbor — cap PVC sizes (if installed)"
if command -v helm >/dev/null 2>&1 && kubectl get ns harbor >/dev/null 2>&1; then
  HARBOR_VALUES="${LAB_VALUES}/harbor-helm-lab-values.yaml"
  if [[ -f "${HARBOR_VALUES}" ]]; then
    helm upgrade harbor harbor/harbor -n harbor -f "${HARBOR_VALUES}" --reuse-values --timeout 10m 2>/dev/null \
      || log "WARN: Harbor helm upgrade skipped (existing PVC sizes may be unchanged)"
  fi
fi

bash "${SCRIPT_DIR}/lab-pvc-retain.sh" guard
bash "${SCRIPT_DIR}/lab-pvc-retain.sh" status

echo ""
echo "=============================================="
echo " Lab data persistence"
echo "=============================================="
echo "  PaaS login/users     → PVC postgres-pvc (paas ns)"
echo "  Jenkins jobs/plugins → PVC jenkins (cicd ns)"
echo "  Sonar tokens/projects→ PVC sonarqube (after helm upgrade)"
echo "  DT BOMs/API keys     → PVC dtrack API (dependency-track ns)"
echo "  Harbor images      → Harbor PVCs (harbor ns)"
echo ""
echo "  NEVER delete PVCs unless FORCE_WIPE=1 on wipe scripts."
echo "  Restore UI only:    bash paas/scripts/lab.sh frontend-up"
echo "  Restore DB only:    bash paas/scripts/lab.sh postgres-up"
echo "  Reset login:        bash paas/scripts/lab.sh auth-reset reset <email> <pass>"
echo "=============================================="
