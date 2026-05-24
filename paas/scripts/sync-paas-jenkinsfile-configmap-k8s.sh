#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
JENKINSFILE="${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy"
NS="${PAAS_NS:-paas}"
DEPLOY="${PAAS_FRONTEND_DEPLOY:-frontend}"
CM="${PAAS_JENKINSFILE_CM:-paas-jenkinsfile}"

if [[ ! -f "${JENKINSFILE}" ]]; then
  echo "ERROR: missing ${JENKINSFILE}" >&2
  exit 1
fi
if ! grep -qF 'crane-next16-202605' "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing crane-next16-202605 — git pull origin main" >&2
  exit 1
fi

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "==> ConfigMap ${CM} in namespace ${NS}"
kubectl create configmap "${CM}" -n "${NS}" \
  --from-file="Jenkinsfile.paas-deploy=${JENKINSFILE}" \
  --dry-run=client -o yaml | kubectl apply -f -

if ! kubectl get deployment "${DEPLOY}" -n "${NS}" >/dev/null 2>&1; then
  echo "WARN: deployment/${DEPLOY} not found in ${NS} — ConfigMap created; mount manually or re-run after deploy"
  exit 0
fi

if kubectl get deployment "${DEPLOY}" -n "${NS}" -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -qxF "${CM}"; then
  echo "==> Volume ${CM} already on deployment/${DEPLOY}"
else
  echo "==> Patch deployment/${DEPLOY} to mount ${CM} at /app/paas-bundled/paas/jenkins"
  kubectl patch deployment "${DEPLOY}" -n "${NS}" --type=strategic -p "$(cat <<EOF
{
  "spec": {
    "template": {
      "spec": {
        "volumes": [
          {
            "name": "${CM}",
            "configMap": { "name": "${CM}" }
          }
        ],
        "containers": [
          {
            "name": "frontend",
            "volumeMounts": [
              {
                "name": "${CM}",
                "mountPath": "/app/paas-bundled/paas/jenkins",
                "readOnly": true
              }
            ]
          }
        ]
      }
    }
  }
}
EOF
)"
fi

kubectl rollout restart deployment/"${DEPLOY}" -n "${NS}"
kubectl rollout status deployment/"${DEPLOY}" -n "${NS}" --timeout=300s
echo "OK: PaaS inline sync will read Jenkinsfile from ConfigMap (crane-next16-202605)"
