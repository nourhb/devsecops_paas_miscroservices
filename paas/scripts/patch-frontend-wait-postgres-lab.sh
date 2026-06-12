#!/usr/bin/env bash
# Frontend init container: do not start until postgres:5432 is reachable (fixes login after reboot).
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"

if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "WARN: deployment/frontend not found in ${PAAS_NS} — skip init container patch"
  exit 0
fi

if kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.initContainers[*].name}' 2>/dev/null | grep -q wait-for-postgres; then
  echo "OK: frontend already has wait-for-postgres init container"
  exit 0
fi

echo "==> Patch deployment/frontend — init container waits for postgres.paas.svc.cluster.local:5432"
kubectl patch deployment frontend -n "${PAAS_NS}" --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/initContainers",
    "value": [
      {
        "name": "wait-for-postgres",
        "image": "busybox:1.36",
        "command": [
          "sh",
          "-c",
          "echo waiting for postgres.paas.svc.cluster.local:5432; until nc -z postgres.paas.svc.cluster.local 5432; do sleep 3; done; echo postgres ready"
        ]
      }
    ]
  }
]' 2>/dev/null || {
  echo "WARN: json patch failed (initContainers may already exist) — trying merge"
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p '
spec:
  template:
    spec:
      initContainers:
        - name: wait-for-postgres
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              echo waiting for postgres.paas.svc.cluster.local:5432
              until nc -z postgres.paas.svc.cluster.local 5432; do sleep 3; done
              echo postgres ready
'
}

kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s || true
echo "OK: frontend will not serve traffic until Postgres is up"
