#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${DIR}/normalize-harbor-env-lab.sh" || true
bash "${DIR}/configure-k3s-harbor-http-lab.sh" || true
bash "${DIR}/recover-harbor-registry-lab.sh" || true
bash "${DIR}/fix-harbor-cosign-realm-lab.sh" || true
bash "${DIR}/apply-kyverno-cosign-lab.sh" || true
kubectl apply -f "${DIR}/../k8s-manifests/kyverno/require-non-root.yaml" 2>/dev/null || true
kubectl patch clusterpolicy require-non-root -n kyverno --type=json \
  -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]' 2>/dev/null || \
kubectl patch clusterpolicy require-non-root --type=json \
  -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]' 2>/dev/null || true
