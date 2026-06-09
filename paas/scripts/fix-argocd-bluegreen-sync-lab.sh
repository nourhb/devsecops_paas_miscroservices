#!/usr/bin/env bash
# Diagnose + force Argo sync when BlueGreen values exist but cluster still has rolling Deployment.
set -euo pipefail

APP="${1:?usage: fix-argocd-bluegreen-sync-lab.sh <projectName>}"
PROJECT="$(echo "${APP}" | sed 's/^paas-//')"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GITOPS="${GITOPS:-${HOME}/gitops}"
CHART="${GITOPS}/apps/${PROJECT}"
VALUES="${CHART}/values.yaml"
ARGO_NS="${ARGOCD_NAMESPACE:-argocd}"

# shellcheck source=lib/argo-sync-lab.sh
source "${SCRIPT_DIR}/lib/argo-sync-lab.sh"

echo "==> Chart ${CHART}"
[[ -d "${CHART}/templates" ]] || { echo "ERROR: missing ${CHART}/templates" >&2; exit 1; }
[[ -f "${VALUES}" ]] || { echo "ERROR: missing ${VALUES}" >&2; exit 1; }

for f in deployment-bluegreen.yaml deployment.yaml service.yaml; do
  if [[ -f "${CHART}/templates/${f}" ]]; then
    echo "  OK templates/${f}"
  else
    echo "  MISSING templates/${f} — run: bash paas/scripts/sync-gitops-bluegreen-template-lab.sh" >&2
    exit 1
  fi
done

grep -qE '^deploymentStrategy:[[:space:]]*BlueGreen' "${VALUES}" || {
  echo "WARN: ${VALUES} missing deploymentStrategy: BlueGreen"
}

echo ""
echo "==> helm template preview (deployments + service selector)"
if command -v helm >/dev/null 2>&1; then
  helm template "paas-${PROJECT}" "${CHART}" -f "${VALUES}" 2>/dev/null \
    | grep -E '^kind:|^  name:|paas.io/slot|deploymentStrategy' | head -40 || true
else
  echo "WARN: helm not installed — skip template preview"
fi

echo ""
echo "==> Argo Application ${APP}"
if ! kubectl get application "${APP}" -n "${ARGO_NS}" >/dev/null 2>&1; then
  echo "ERROR: Application ${APP} not in ${ARGO_NS}" >&2
  exit 1
fi

kubectl get application "${APP}" -n "${ARGO_NS}" -o jsonpath='  sync={.status.sync.status} health={.status.health.status} rev={.status.sync.revision}{"\n"}' 2>/dev/null || true
kubectl get application "${APP}" -n "${ARGO_NS}" -o jsonpath='  operation={.status.operationState.phase}{" "}{.status.operationState.message}{"\n"}' 2>/dev/null || true
kubectl get application "${APP}" -n "${ARGO_NS}" -o jsonpath='{range .status.conditions[*]}  condition {.type}={.message}{"\n"}{end}' 2>/dev/null || true

echo ""
echo "==> Clear stuck operation (if any)"
kubectl patch application "${APP}" -n "${ARGO_NS}" --type json \
  -p='[{"op": "remove", "path": "/operation"}]' 2>/dev/null || true
kubectl patch application "${APP}" -n "${ARGO_NS}" --type json \
  -p='[{"op": "remove", "path": "/status/operationState"}]' 2>/dev/null || true

echo "==> Hard refresh + sync"
kubectl annotate application "${APP}" -n "${ARGO_NS}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null
sleep 2
argo_sync_app_lab "${APP}" || true

echo "==> Wait (up to 360s)"
argo_wait_app_lab "${APP}" 360 || true

echo ""
echo "==> Cluster deployments in namespace ${PROJECT}"
kubectl get deploy -n "${PROJECT}" -o wide 2>/dev/null || true

OLD="${APP}-${PROJECT}"
if kubectl get deploy "${OLD}" -n "${PROJECT}" >/dev/null 2>&1; then
  if kubectl get deploy "${OLD}-blue" -n "${PROJECT}" >/dev/null 2>&1; then
    echo ""
    echo "==> Remove legacy rolling Deployment ${OLD} (BlueGreen uses ${OLD}-blue / ${OLD}-green)"
    echo "    GitOps prune is off — old Deployment is not auto-deleted."
    kubectl delete deploy "${OLD}" -n "${PROJECT}" --wait=true
  else
    echo "WARN: legacy ${OLD} still present; blue/green Deployments not created yet."
    echo "      Check: kubectl describe application ${APP} -n ${ARGO_NS}"
    echo "      helm template paas-${PROJECT} ${CHART} -f ${VALUES} | less"
  fi
fi

echo ""
echo "==> Pods"
kubectl get pods -n "${PROJECT}" -l "app.kubernetes.io/instance=${APP}" -o wide 2>/dev/null || true

HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://${PROJECT}.192.168.56.129.nip.io:30659/" 2>/dev/null || echo "?")"
echo "HTTP ${PROJECT}: ${HTTP_CODE}"
