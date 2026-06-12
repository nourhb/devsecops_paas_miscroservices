#!/usr/bin/env bash
# Why PaaS Security shows Kyverno FAIL while Cosign OK?
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
SA="system:serviceaccount:${PAAS_NS}:paas-frontend"

pass() { echo "  OK: $*"; }
fail() { echo "  FAIL: $*" >&2; }

echo "=== Kyverno ClusterPolicies (cluster) ==="
if kubectl get clusterpolicies.kyverno.io require-signed-images require-non-root \
  -o custom-columns=NAME:.metadata.name,ACTION:.spec.validationFailureAction 2>/dev/null; then
  for p in require-signed-images require-non-root; do
    action="$(kubectl get clusterpolicy "${p}" -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || echo missing)"
    if [[ "${action}" == "Enforce" ]]; then
      pass "${p} validationFailureAction=Enforce"
    else
      fail "${p} is '${action}' (need Enforce) — run: bash paas/scripts/apply-kyverno-policies-lab.sh"
    fi
  done
else
  fail "ClusterPolicies missing — run: bash paas/scripts/apply-kyverno-policies-lab.sh"
fi

echo ""
echo "=== Frontend ServiceAccount RBAC (PaaS lists clusterpolicies) ==="
if kubectl auth can-i list clusterpolicies.kyverno.io --as="${SA}" 2>/dev/null | grep -q yes; then
  pass "paas-frontend can list clusterpolicies.kyverno.io"
else
  fail "paas-frontend cannot list clusterpolicies — apply updated RBAC:"
  echo "       kubectl apply -f paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml"
  echo "       bash paas/scripts/enable-paas-kubernetes-lab.sh"
fi

echo ""
echo "=== Frontend pod env ==="
for v in KUBERNETES_ENABLED POLICY_ENGINE KYVERNO_POLICIES_ENABLED; do
  val="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- printenv "${v}" 2>/dev/null || true)"
  if [[ -n "${val}" ]]; then
    pass "${v}=${val}"
  else
    fail "${v} unset in frontend pod — run: bash paas/scripts/sync-paas-frontend-env-k8s.sh"
  fi
done

echo ""
echo "=== ServiceAccount on deployment/frontend ==="
sa="$(kubectl get deploy frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null || true)"
if [[ "${sa}" == "paas-frontend" ]]; then
  pass "serviceAccountName=paas-frontend"
else
  fail "serviceAccountName='${sa:-default}' — run: bash paas/scripts/enable-paas-kubernetes-lab.sh"
fi

echo ""
echo "=== cosign.pub on frontend (optional verify) ==="
head="$(kubectl exec -n "${PAAS_NS}" deploy/frontend -- sh -c 'head -c 22 "${COSIGN_PUBLIC_KEY_PATH:-/etc/cosign/cosign.pub}" 2>/dev/null || head -c 22 "$COSIGN_PUBLIC_KEY" 2>/dev/null' 2>/dev/null || true)"
if [[ "${head}" == *"BEGIN PUBLIC KEY"* ]]; then
  pass "Cosign public key present in pod"
else
  echo "  WARN: cosign pubkey not readable — run: bash paas/scripts/mount-cosign-pub-frontend-lab.sh"
fi

echo ""
echo "=== Kyverno admission webhook (cluster enforcement — not required for PaaS UI green) ==="
eps="$(kubectl get endpoints kyverno-svc -n kyverno -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
if [[ -n "${eps}" ]]; then
  pass "kyverno-svc has endpoints (${eps})"
else
  echo "  WARN: kyverno-svc has no endpoints — repair: bash paas/scripts/recover-kyverno-lab.sh"
fi

echo ""
echo "If ClusterPolicies + RBAC + env are OK, refresh PaaS → Security (hard refresh)."
echo "One-shot UI fix: bash paas/scripts/apply-kyverno-policies-only-lab.sh"
echo "Full fix:        bash paas/scripts/fix-kyverno-policy-validation-lab.sh"
