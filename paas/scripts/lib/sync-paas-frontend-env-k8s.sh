#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"
CONTAINER_NAME="${CONTAINER_NAME:-frontend}"
SECRET_NAME="${SECRET_NAME:-paas-frontend-env}"
umask 077
FILTERED="$(mktemp "${TMPDIR:-/tmp}/paas-frontend-env.XXXXXX")"
trap 'rm -f "${FILTERED}"' EXIT
if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2
  exit 1
fi
if ! kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "ERROR: deployment/${DEPLOY_NAME} not found in namespace ${PAAS_NS}" >&2
  kubectl get deploy -A 2>/dev/null | grep -i frontend || true
  exit 1
fi
awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*$/ { next }
  match($0, /^[A-Za-z_][A-Za-z0-9_]*=/) {
    eq = index($0, "=")
    key = substr($0, 1, eq - 1)
    val = substr($0, eq + 1)
    if (val ~ /^".*"$/) {
      val = substr(val, 2, length(val) - 2)
    } else if (val ~ /^'\''.*'\''$/) {
      val = substr(val, 2, length(val) - 2)
    }
    env[key] = val
  }
  END {
    for (k in env) print k "=" env[k]
  }
' "${ENV_FILE}" > "${FILTERED}"
if ! grep -qE '^DATABASE_URL=.*postgres\.paas\.svc\.cluster\.local' "${FILTERED}"; then
  echo "ERROR: DATABASE_URL must use postgres.paas.svc.cluster.local for Kubernetes PaaS." >&2
  echo "       Do not use postgres:5432 (Docker Compose) or localhost." >&2
  echo "       Fix ${ENV_FILE} then re-run this script." >&2
  exit 1
fi
chmod 600 "${FILTERED}" 2>/dev/null || true
if ! grep -qE '^SMTP_HOST=' "${FILTERED}"; then
  echo "WARN: SMTP_HOST missing in ${ENV_FILE} — verification mail will use console mode only."
fi
echo "==> Secret ${SECRET_NAME} from ${ENV_FILE} ($(wc -l < "${FILTERED}") keys)"
kubectl create secret generic "${SECRET_NAME}" \
  --from-env-file="${FILTERED}" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -
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
REPLICAS="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
if [[ "${PAAS_SKIP_ROLLOUT:-}" == "1" ]] || [[ "${REPLICAS}" -eq 0 ]]; then
  echo "==> Skip rollout (replicas=${REPLICAS}); pod will pick up env on next start"
else
  echo "==> Rollout"
  kubectl rollout restart deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}"
  kubectl rollout status deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s
fi
echo "==> SMTP in pod (values hidden)"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- sh -c '
  for v in SMTP_HOST SMTP_PORT SMTP_SECURE SMTP_USER MAIL_FROM APP_BASE_URL; do
    eval "val=\$$v"
    if [ -n "$val" ]; then echo "$v=set"; else echo "$v=MISSING"; fi
  done
  if [ -n "$SMTP_PASS" ]; then echo "SMTP_PASS=set"; else echo "SMTP_PASS=MISSING"; fi
' 2>/dev/null || echo "WARN: could not exec into pod yet — wait for rollout, then re-run check"
echo "==> Security integrations in pod (values hidden)"
SECURITY_OK=1
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- sh -c '
  for v in SONAR_BASE_URL SONAR_TOKEN DEPENDENCY_TRACK_BASE_URL DEPENDENCY_TRACK_API_KEY JENKINS_PAAS_FAST_PIPELINE; do
    eval "val=\$$v"
    if [ -n "$val" ]; then echo "$v=set"; else echo "$v=MISSING"; fi
  done
' 2>/dev/null || { echo "WARN: could not exec into pod yet"; SECURITY_OK=0; }
if grep -qE '^SONAR_TOKEN=' "${ENV_FILE}" && grep -qE '^DEPENDENCY_TRACK_API_KEY=' "${ENV_FILE}"; then
  :
else
  echo ""
  echo "WARN: ${ENV_FILE} is missing SONAR_TOKEN and/or DEPENDENCY_TRACK_API_KEY."
  echo "      Jenkins Steps 4–5 will skip Sonar/Dependency-Track until these are set."
  echo "      Run: bash paas/scripts/lab.sh jenkins"
  SECURITY_OK=0
fi
echo ""
if [[ "${SECURITY_OK}" -eq 1 ]]; then
  echo "OK. Trigger a NEW deploy from PaaS; Jenkins console should show SBOM upload + Sonar analysis (not 'non configuré')."
else
  echo "Fix security env keys above, re-run this script, then deploy again."
fi
echo "Register/mail: API should return mailDelivery=smtp when SMTP_* are set."
echo "If mail still fails: kubectl logs -n ${PAAS_NS} deploy/${DEPLOY_NAME} --tail=80 | grep -E 'auth-mail|register|SMTP|EAUTH'"
