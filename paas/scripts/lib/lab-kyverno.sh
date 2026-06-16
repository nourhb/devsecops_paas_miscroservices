#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_NS="${PAAS_NS:-paas}"

kyverno_patch_workloads() {
  if kubectl get deployment postgres -n "${PAAS_NS}" >/dev/null 2>&1; then
    kubectl patch deployment postgres -n "${PAAS_NS}" --type=strategic -p "$(cat <<'PATCH'
{
  "spec": {
    "template": {
      "spec": {
        "securityContext": {
          "runAsNonRoot": true,
          "runAsUser": 70,
          "fsGroup": 70
        },
        "containers": [
          {
            "name": "postgres",
            "securityContext": {
              "runAsNonRoot": true,
              "runAsUser": 70,
              "allowPrivilegeEscalation": false
            }
          }
        ]
      }
    }
  }
}
PATCH
)" 2>/dev/null || true
  fi
  if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
    echo "WARN: deployment/frontend not found in ${PAAS_NS}" >&2
    return 0
  fi
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p "$(cat <<'PATCH'
{
  "spec": {
    "template": {
      "spec": {
        "securityContext": {
          "runAsNonRoot": true,
          "runAsUser": 1001,
          "fsGroup": 1001
        },
        "containers": [
          {
            "name": "frontend",
            "securityContext": {
              "runAsNonRoot": true,
              "runAsUser": 1001,
              "allowPrivilegeEscalation": false
            }
          }
        ]
      }
    }
  }
}
PATCH
)"
  echo "OK: paas frontend/postgres patched for require-non-root"
}

kyverno_bootstrap() {
  bash "${SCRIPT_DIR}/lab-harbor.sh" bootstrap || true
  bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" || true
  kubectl apply -f "${SCRIPT_DIR}/../../k8s-manifests/kyverno/require-non-root.yaml" 2>/dev/null || true
  kubectl patch clusterpolicy require-non-root -n kyverno --type=json \
    -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]' 2>/dev/null || \
  kubectl patch clusterpolicy require-non-root --type=json \
    -p='[{"op":"replace","path":"/spec/validationFailureAction","value":"Enforce"}]' 2>/dev/null || true
}

cmd="${1:-workloads}"
case "${cmd}" in
  workloads) kyverno_patch_workloads ;;
  apply) bash "${SCRIPT_DIR}/apply-kyverno-cosign-lab.sh" ;;
  bootstrap) kyverno_bootstrap ;;
  *)
    echo "usage: lab-kyverno.sh [workloads|apply|bootstrap]" >&2
    exit 1 ;;
esac
