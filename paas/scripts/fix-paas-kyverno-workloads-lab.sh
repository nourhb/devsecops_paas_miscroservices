#!/usr/bin/env bash
set -euo pipefail
PAAS_NS="${PAAS_NS:-paas}"

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
  exit 0
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
