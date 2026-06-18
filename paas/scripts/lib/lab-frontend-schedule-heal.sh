#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'

echo "=============================================="
echo " lab-frontend-schedule-heal"
echo "=============================================="

kubectl get nodes -o wide 2>/dev/null || true

CUR_IMAGE="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  if [[ "${PAAS_UNPIN_FRONTEND:-}" == "1" ]]; then
    NS_JSON="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
    if [[ -n "${NS_JSON}" && "${NS_JSON}" != "{}" ]]; then
      echo "==> Remove frontend nodeSelector (${NS_JSON}) — PAAS_UNPIN_FRONTEND=1"
      kubectl patch deployment frontend -n "${PAAS_NS}" --type=json \
        -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' 2>/dev/null \
        || kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic \
          -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
    fi
  elif [[ "${CUR_IMAGE}" == *paas-frontend:recovery* ]]; then
    echo "==> Recovery image — pin frontend on master (imagePullPolicy Never)"
    kubectl patch deployment frontend -n "${PAAS_NS}" --type=merge -p "$(cat <<PATCH
{
  "spec": {
    "replicas": 1,
    "strategy": {"type": "Recreate"},
    "template": {
      "spec": {
        "nodeSelector": {"kubernetes.io/hostname": "master"},
        "tolerations": [{
          "key": "node.kubernetes.io/disk-pressure",
          "operator": "Exists",
          "effect": "NoSchedule"
        }],
        "containers": [{
          "name": "frontend",
          "image": "${CUR_IMAGE}",
          "imagePullPolicy": "Never"
        }]
      }
    }
  }
}
PATCH
)"
  else
    NS_JSON="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
    if [[ -n "${NS_JSON}" && "${NS_JSON}" != "{}" ]]; then
      echo "OK: keeping frontend nodeSelector (${NS_JSON})"
    else
      echo "OK: no frontend nodeSelector"
    fi
  fi
fi

echo "==> Ensure DATABASE_URL uses in-cluster postgres service"
kubectl set env deployment/frontend -n "${PAAS_NS}" \
  DATABASE_URL="${DB_URL}" --containers=frontend 2>/dev/null \
  || kubectl set env deployment/frontend -n "${PAAS_NS}" DATABASE_URL="${DB_URL}" || true

kubectl rollout resume deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true

kubectl delete pod -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 2>/dev/null || true

if [[ -f "${ENV_FILE}" ]]; then
  PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-0}" ENV_FILE="${ENV_FILE}" \
    bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" || true
else
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}"
fi

kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s
kubectl wait --for=condition=available deployment/frontend -n "${PAAS_NS}" --timeout=120s
bash "${SCRIPT_DIR}/check-paas-lab-health.sh"
