#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"

kubectl get deploy,rs,pods,svc,endpoints -n "${PAAS_NS}" 2>/dev/null || true
bash "${SCRIPT_DIR}/fix-paas-kyverno-workloads-lab.sh" || true
kubectl rollout undo deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
