#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
MANIFEST="${REPO_ROOT}/paas/k8s-manifests/lab/postgres-in-paas.yaml"
PG_IMAGE="postgres:15-alpine"

echo "=============================================="
echo " pin-postgres-pg15-now (lab data is PG15 only)"
echo "=============================================="

bash "${SCRIPT_DIR}/lab-postgres-safe.sh" begin pin-pg15

bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" 2>/dev/null || true

if [[ ! -f "${MANIFEST}" ]]; then
  echo "FAIL: missing ${MANIFEST}" >&2
  exit 1
fi

if grep -qE 'postgres:16' "${MANIFEST}"; then
  echo "==> Fix manifest on disk (was PG16 — breaks existing PVC data)"
  sed -i 's|postgres:16-alpine|postgres:15-alpine|g; s|postgres:16|postgres:15-alpine|g' "${MANIFEST}"
fi
grep -n 'image:.*postgres' "${MANIFEST}" || true

echo "==> Pause auto-heal while pinning (optional: rm /var/tmp/paas-lab-no-auto-heal to re-enable)"
touch /var/tmp/paas-lab-no-auto-heal 2>/dev/null || sudo touch /var/tmp/paas-lab-no-auto-heal 2>/dev/null || true

echo "==> Scale down + delete deployment (keeps PVC postgres-pvc)"
kubectl scale deployment/postgres -n "${PAAS_NS}" --replicas=0 2>/dev/null || true
sleep 8
kubectl delete deployment/postgres -n "${PAAS_NS}" --ignore-not-found
kubectl delete rs -n "${PAAS_NS}" -l app=postgres 2>/dev/null || true

echo "==> Apply manifest (PG15) — split apply if API is slow"
apply_part() {
  local label="$1" file="$2"
  local n=1
  while (( n <= 5 )); do
    if kubectl apply --validate=false --request-timeout=180s -f "${file}"; then
      echo "OK: ${label}"
      return 0
    fi
    echo "WARN: ${label} apply failed (attempt ${n}/5) — k3s API slow"
    bash "${SCRIPT_DIR}/lab-k3s-ensure.sh" 2>/dev/null || true
    sleep 15
    n=$((n + 1))
  done
  echo "FAIL: could not apply ${label}" >&2
  return 1
}

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
awk '/^---$/{c++; next} {print > ("'"${tmp}"'/part-" c ".yaml")}' "${MANIFEST}"
apply_part "postgres-pvc" "${tmp}/part-0.yaml"
apply_part "postgres-service" "${tmp}/part-1.yaml"
apply_part "postgres-deployment" "${tmp}/part-2.yaml"

kubectl set image deployment/postgres -n "${PAAS_NS}" postgres="${PG_IMAGE}" 2>/dev/null || true
kubectl patch deployment postgres -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
{
  "spec": {
    "strategy": {"type": "Recreate"},
    "template": {
      "metadata": {
        "annotations": {
          "paas.lab/postgres-version": "15",
          "kubectl.kubernetes.io/restartedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        }
      },
      "spec": {
        "containers": [{
          "name": "postgres",
          "image": "${PG_IMAGE}",
          "imagePullPolicy": "IfNotPresent"
        }]
      }
    }
  }
}
PATCH
)"

want="$(kubectl get deployment postgres -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
if [[ "${want}" != "${PG_IMAGE}" ]]; then
  echo "FAIL: deployment image is ${want} — expected ${PG_IMAGE}" >&2
  echo "  Check Argo CD / another controller:" >&2
  kubectl get applications.argoproj.io -A 2>/dev/null | grep -i paas || true
  exit 1
fi
echo "OK: deployment spec image=${want}"

kubectl rollout status deployment/postgres -n "${PAAS_NS}" --timeout=240s
kubectl exec -n "${PAAS_NS}" deploy/postgres -- pg_isready -U postgres -d paas
kubectl logs -n "${PAAS_NS}" -l app=postgres --tail=5

echo "==> Restart frontend (login needs DB)"
kubectl rollout restart deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s 2>/dev/null || true

hc="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "http://${NODE_IP:-192.168.56.129}:30100/api/health" 2>/dev/null || echo 000)"
echo "==> UI health HTTP ${hc}"
echo "=============================================="
echo "Done. Login: http://${NODE_IP:-192.168.56.129}:30100/login"
echo "Re-enable watchdog: rm /var/tmp/paas-lab-no-auto-heal"
echo "=============================================="
