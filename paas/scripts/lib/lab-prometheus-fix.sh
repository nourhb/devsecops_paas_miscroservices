#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"

ok() { echo "OK: $*"; }
warn() { echo "WARN: $*" >&2; }

echo "=============================================="
echo " lab-prometheus-fix — monitoring charts"
echo "=============================================="

export PROMETHEUS_RECOVER_SKIP_GRAFANA="${PROMETHEUS_RECOVER_SKIP_GRAFANA:-1}"

if bash "${SCRIPT_DIR}/probe-prometheus-lab.sh" 2>/dev/null; then
  ok "Prometheus already reachable — skip recover (no pod restarts)"
else
  bash "${SCRIPT_DIR}/lab-prometheus-recover.sh" || warn "prometheus recover incomplete — continuing"
fi

bash "${SCRIPT_DIR}/bootstrap-integrations-lab.sh" || true

kubectl apply --validate=false -f "${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"
bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s

if bash "${SCRIPT_DIR}/probe-prometheus-lab.sh"; then
  ok "Prometheus reachable from lab"
else
  warn "Prometheus probe still failing — check: kubectl get pods -n ${MON_NS}"
  warn "If ImagePullBackOff: fix VM DNS (getent hosts quay.io) then wait — do not helm uninstall"
fi

echo "=============================================="
echo "Done. Refresh the monitoring page in the PaaS UI."
echo "If charts still flat, rebuild frontend:"
echo "  bash paas/scripts/lab.sh frontend"
echo "=============================================="
