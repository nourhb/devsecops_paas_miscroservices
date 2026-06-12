#!/usr/bin/env bash
# Repair Kyverno when kyverno-svc has no endpoints (admission controller unhealthy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NS="${KYVERNO_NS:-kyverno}"
RELEASE="${KYVERNO_RELEASE:-kyverno}"

kyverno_has_endpoints() {
  local eps
  eps="$(kubectl get endpoints kyverno-svc -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "${eps}" ]]
}

echo "=== Kyverno pods ==="
kubectl get pods -n "${NS}" -o wide 2>/dev/null || echo "WARN: namespace ${NS} missing"

echo ""
echo "=== Services / endpoints ==="
kubectl get svc,endpoints -n "${NS}" 2>/dev/null || true

echo ""
echo "=== Recent admission-controller logs ==="
kubectl logs -n "${NS}" -l app.kubernetes.io/component=admission-controller --tail=40 2>/dev/null \
  || kubectl logs -n "${NS}" deploy/kyverno-admission-controller --tail=40 2>/dev/null \
  || true

if ! command -v helm >/dev/null 2>&1; then
  echo "ERROR: helm required to reinstall Kyverno" >&2
  exit 1
fi

echo ""
echo "==> Helm upgrade --install Kyverno (${RELEASE} in ${NS})"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update kyverno >/dev/null 2>&1 || true
helm upgrade --install "${RELEASE}" kyverno/kyverno -n "${NS}" --create-namespace \
  --set admissionController.replicas=1 \
  --set backgroundController.replicas=1 \
  --set cleanupController.replicas=1 \
  --set reportsController.replicas=1 \
  --timeout 10m

echo ""
echo "==> Wait for admission controller rollout"
kubectl rollout status deployment/kyverno-admission-controller -n "${NS}" --timeout=300s 2>/dev/null \
  || kubectl rollout status deployment -n "${NS}" --timeout=300s 2>/dev/null \
  || true

for i in $(seq 1 36); do
  if kyverno_has_endpoints; then
    kubectl get endpoints kyverno-svc -n "${NS}" -o wide
    echo "OK: kyverno-svc has endpoints"
    break
  fi
  echo "  waiting kyverno-svc endpoints (${i}/36)…"
  sleep 5
  if [[ "${i}" -eq 36 ]]; then
    echo "WARN: kyverno-svc still has no endpoints" >&2
    kubectl describe pods -n "${NS}" -l app.kubernetes.io/component=admission-controller 2>/dev/null | tail -40
    kubectl get events -n "${NS}" --sort-by=.lastTimestamp 2>/dev/null | tail -15
    exit 1
  fi
done

echo ""
echo "OK — Kyverno admission webhook healthy."
echo "If ClusterPolicies missing: bash paas/scripts/apply-kyverno-policies-only-lab.sh"
