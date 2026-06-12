#!/usr/bin/env bash
# Apply ClusterPolicies for PaaS Security UI (bypasses broken policy webhooks if needed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
KYVERNO_DIR="${REPO_ROOT}/paas/k8s-manifests/kyverno"
NS="${KYVERNO_NS:-kyverno}"

if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  echo "ERROR: Kyverno CRD missing — run: bash paas/scripts/recover-kyverno-lab.sh" >&2
  exit 1
fi

[[ -f "${KYVERNO_DIR}/require-non-root.yaml" ]] || {
  echo "ERROR: missing ${KYVERNO_DIR}/require-non-root.yaml" >&2
  exit 1
}

kyverno_svc_ready() {
  local eps
  eps="$(kubectl get endpoints kyverno-svc -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
  [[ -n "${eps}" ]]
}

apply_manifest() {
  local file="$1"
  if kubectl apply -f "${file}" 2>/tmp/kyverno-apply.err; then
    return 0
  fi
  if grep -qE 'mutate-policy\.kyverno|no endpoints available for service "kyverno-svc"' /tmp/kyverno-apply.err 2>/dev/null; then
    echo "WARN: Kyverno policy webhook blocked apply — using lab bypass"
    cat /tmp/kyverno-apply.err >&2
    bash "${SCRIPT_DIR}/bypass-kyverno-policy-webhook-lab.sh"
    kubectl apply -f "${file}"
    return 0
  fi
  cat /tmp/kyverno-apply.err >&2
  return 1
}

if ! kyverno_svc_ready; then
  echo "NOTE: kyverno-svc has no endpoints — will bypass policy webhooks if apply fails"
fi

apply_manifest "${KYVERNO_DIR}/require-non-root.yaml"

if [[ -f "${KEYDIR}/cosign.pub" ]]; then
  python3 "${SCRIPT_DIR}/render-kyverno-signed-images-lab.py" \
    "${KEYDIR}/cosign.pub" \
    "${KYVERNO_DIR}/require-signed-images.yaml" \
    "${KYVERNO_DIR}/.require-signed-images.lab.yaml"
  apply_manifest "${KYVERNO_DIR}/.require-signed-images.lab.yaml"
else
  echo "WARN: ${KEYDIR}/cosign.pub missing — only require-non-root applied"
  echo "  Run: bash paas/scripts/sync-cosign-keys-lab.sh"
fi

kubectl get clusterpolicies.kyverno.io require-signed-images require-non-root \
  -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction 2>/dev/null || true

echo ""
echo "OK: ClusterPolicies applied — refresh PaaS → Security."
echo "Repair Kyverno admission (cluster enforcement): bash paas/scripts/recover-kyverno-lab.sh"
