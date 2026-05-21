#!/usr/bin/env bash
# Push paas/frontend/docker-compose.env into the Kubernetes frontend pod.
# Docker Compose reads that file automatically; deployment/frontend does NOT unless you run this.
#
# Usage (on lab master, from repo root):
#   bash paas/scripts/sync-paas-frontend-env-k8s.sh
#   ENV_FILE=/path/to/docker-compose.env bash paas/scripts/sync-paas-frontend-env-k8s.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"
CONTAINER_NAME="${CONTAINER_NAME:-frontend}"
SECRET_NAME="${SECRET_NAME:-paas-frontend-env}"
FILTERED="/tmp/paas-frontend-env-$$.env"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2
  exit 1
fi

if ! kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "ERROR: deployment/${DEPLOY_NAME} not found in namespace ${PAAS_NS}" >&2
  kubectl get deploy -A 2>/dev/null | grep -i frontend || true
  exit 1
fi

# kubectl --from-env-file accepts KEY=VALUE only (no comments / duplicates).
awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
    eq = index($0, "=")
    key = substr($0, 1, eq - 1)
    env[key] = substr($0, eq + 1)
  }
  END {
    for (k in env) print k "=" env[k]
  }
' "${ENV_FILE}" > "${FILTERED}"

if ! grep -qE '^SMTP_HOST=' "${FILTERED}"; then
  echo "WARN: SMTP_HOST missing in ${ENV_FILE} — verification mail will use console mode only."
fi

echo "==> Secret ${SECRET_NAME} from ${ENV_FILE} ($(wc -l < "${FILTERED}") keys)"
kubectl create secret generic "${SECRET_NAME}" \
  --from-env-file="${FILTERED}" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

rm -f "${FILTERED}"

echo "==> Attach envFrom secret to deployment/${DEPLOY_NAME}"
kubectl patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
{
  "spec": {
    "template": {
      "spec": {
        "containers": [
          {
            "name": "${CONTAINER_NAME}",
            "envFrom": [
              { "secretRef": { "name": "${SECRET_NAME}" } }
            ]
          }
        ]
      }
    }
  }
}
PATCH
)"

echo "==> Rollout"
kubectl rollout restart deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}"
kubectl rollout status deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s

echo "==> SMTP in pod (values hidden)"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- sh -c '
  for v in SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER MAIL_FROM APP_BASE_URL; do
    eval "val=\$$v"
    if [ -n "$val" ]; then echo "$v=set"; else echo "$v=MISSING"; fi
  done
  if [ -n "$SMTP_PASS" ]; then echo "SMTP_PASS=set"; else echo "SMTP_PASS=MISSING"; fi
' 2>/dev/null || echo "WARN: could not exec into pod yet — wait for rollout, then re-run check"

echo ""
echo "OK. Register again; API should return mailDelivery=smtp."
echo "If mail still fails, check logs: kubectl logs -n ${PAAS_NS} deploy/${DEPLOY_NAME} --tail=80 | grep -E 'auth-mail|register|SMTP|EAUTH'"
