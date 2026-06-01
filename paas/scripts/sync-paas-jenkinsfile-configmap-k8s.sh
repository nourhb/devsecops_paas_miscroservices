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
if ! grep -qF 'crane-next16-202605-j48300-split' "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing crane-next16-202605-j48300-split — git pull origin main" >&2
  exit 1
fi
if ! grep -qF 'monorepo-app-root-20260531' "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing monorepo-app-root-20260531 (Step 6 mutate in server/ fix) — git pull origin main" >&2
  exit 1
fi
if ! grep -qF 'next-config-build-env-20260531' "${JENKINSFILE}"; then
  echo "ERROR: Jenkinsfile missing next-config-build-env-20260531 (PROJECT_BUILD_ENV_B64 / Firebase) — git pull origin main on dev machine and push" >&2
  exit 1
fi
if ! grep -qF 'cyclonedx-npm (yarn.lock' "${JENKINSFILE}"; then
  echo "WARN: Jenkinsfile missing yarn.lock SCA fix — Security Step 4 may fail on yarn projects"
fi
if ! grep -qF 'JENKINS_NPM_SNAPSHOT_MAX_MB' "${JENKINSFILE}"; then
  echo "WARN: Jenkinsfile missing large snapshot guard — sanhome-style builds may fail on cp -a"
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
echo "OK: PaaS inline sync will read Jenkinsfile from ConfigMap (monorepo-app-root-20260531)"
