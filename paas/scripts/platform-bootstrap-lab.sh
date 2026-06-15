#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
bash "${DIR}/normalize-harbor-env-lab.sh" || true
bash "${DIR}/recover-harbor-registry-lab.sh" || true
bash "${DIR}/fix-harbor-cosign-realm-lab.sh" || true
bash "${DIR}/apply-kyverno-cosign-lab.sh" || true
kubectl patch clusterpolicy require-non-root -n kyverno --type=json \
  -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]' 2>/dev/null || \
kubectl patch clusterpolicy require-non-root --type=json \
  -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]' 2>/dev/null || true
