#!/usr/bin/env bash
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"

echo "=== Nodes ==="
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

VOL="$(kubectl get pvc postgres-pvc -n "${PAAS_NS}" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
if [[ -n "${VOL}" ]]; then
  echo "=== PV ${VOL} (local-path is tied to one node) ==="
  kubectl get pv "${VOL}" -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0] 2>/dev/null \
    || kubectl describe pv "${VOL}" | grep -E 'Node Affinity|kubernetes.io/hostname' || true
fi

echo "=== Remove hostname=master pin (Postgres must run on the PVC node) ==="
kubectl patch deployment postgres -n "${PAAS_NS}" --type=json \
  -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' 2>/dev/null \
  || kubectl patch deployment postgres -n "${PAAS_NS}" -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'

kubectl rollout restart deployment/postgres -n "${PAAS_NS}"
kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=600s
kubectl get pods -n "${PAAS_NS}" -l app=postgres -o wide
