#!/usr/bin/env bash
# One-shot: switch require-signed-images to Audit + mutateDigest=false (lab deploy unblock).
set -euo pipefail
ACTION="${1:-Audit}"
MD="false"
[[ "${ACTION}" == "Enforce" ]] && MD="true"
kubectl patch clusterpolicy require-signed-images --type=json -p="[
  {\"op\":\"replace\",\"path\":\"/spec/validationFailureAction\",\"value\":\"${ACTION}\"},
  {\"op\":\"replace\",\"path\":\"/spec/rules/0/verifyImages/0/mutateDigest\",\"value\":${MD}}
]"
kubectl get clusterpolicy require-signed-images -o jsonpath='action={.spec.validationFailureAction} mutateDigest={.spec.rules[0].verifyImages[0].mutateDigest}{"\n"}'
