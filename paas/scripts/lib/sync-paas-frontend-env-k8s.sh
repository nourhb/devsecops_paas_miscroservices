#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"
CONTAINER_NAME="${CONTAINER_NAME:-frontend}"
SECRET_NAME="${SECRET_NAME:-paas-frontend-env}"
RBAC_MANIFEST="${RBAC_MANIFEST:-${REPO_ROOT}/paas/k8s-manifests/lab/paas-frontend-k8s-rbac.yaml}"
umask 077
FILTERED="$(mktemp "${TMPDIR:-/tmp}/paas-frontend-env.XXXXXX")"
trap 'rm -f "${FILTERED}"' EXIT
KUBECTL_TIMEOUT="${KUBECTL_TIMEOUT:-60s}"
kubectl_apply() {
  kubectl apply --validate=false --request-timeout="${KUBECTL_TIMEOUT}" "$@"
}
kubectl_patch() {
  kubectl patch --request-timeout="${KUBECTL_TIMEOUT}" "$@"
}

echo "==> Kyverno webhook guard (dead admission blocks envFrom patches)"
PAAS_FORCE_KYVERNO_UNBLOCK="${PAAS_FORCE_KYVERNO_UNBLOCK:-1}" \
  PAAS_SKIP_KYVERNO_RESTART=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: env file not found: ${ENV_FILE}" >&2
  exit 1
fi
if [[ -f "${RBAC_MANIFEST}" ]]; then
  echo "==> Apply frontend RBAC (pods/logs + Prometheus service proxy)"
  kubectl_apply -f "${RBAC_MANIFEST}"
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
if grep -qE '^KUBERNETES_ENABLED=true' "${FILTERED}"; then
  if grep -qE '^KUBE_CONFIG_PATH=' "${FILTERED}"; then
    grep -vE '^KUBE_CONFIG_PATH=' "${FILTERED}" > "${FILTERED}.strip" && mv "${FILTERED}.strip" "${FILTERED}"
    echo "==> Stripped KUBE_CONFIG_PATH (in-cluster pod uses serviceAccount token)"
  fi
  if ! grep -qE '^KUBERNETES_ENABLED=' "${FILTERED}"; then
    echo "KUBERNETES_ENABLED=true" >> "${FILTERED}"
  fi
fi
if grep -qE '^DATABASE_URL=.*@(localhost|127\.0\.0\.1):5432' "${FILTERED}"; then
  sed -i 's|@localhost:5432|@postgres:5432|g; s|@127.0.0.1:5432|@postgres:5432|g' "${FILTERED}"
  echo "==> Rewrote DATABASE_URL localhost -> postgres (in-cluster service)"
fi
if ! grep -qE '^DATABASE_URL=.*@postgres(\.paas\.svc\.cluster\.local)?:5432' "${FILTERED}"; then
  echo "ERROR: DATABASE_URL must use in-cluster Postgres (@postgres:5432 or @postgres.paas.svc.cluster.local:5432)." >&2
  echo "       Do not use localhost or host.docker.internal." >&2
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
  --dry-run=client -o yaml | kubectl_apply -f -
echo "==> Attach envFrom secret to deployment/${DEPLOY_NAME}"
attach_env_from() {
  kubectl_patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=strategic -p "$(cat <<PATCH
{
  "spec": {
    "template": {
      "spec": {
        "serviceAccountName": "paas-frontend",
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
}
if ! attach_env_from; then
  echo "WARN: envFrom patch blocked — clearing Kyverno webhooks and retrying"
  PAAS_SKIP_KYVERNO_RESTART=1 bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard 2>/dev/null || true
  attach_env_from || {
    echo "ERROR: could not attach envFrom ${SECRET_NAME} to deployment/${DEPLOY_NAME}" >&2
    exit 1
  }
fi
HAS_ENVFROM="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" \
  -o jsonpath="{.spec.template.spec.containers[?(@.name=='${CONTAINER_NAME}')].envFrom[0].secretRef.name}" 2>/dev/null || true)"
if [[ "${HAS_ENVFROM}" != "${SECRET_NAME}" ]]; then
  echo "ERROR: deployment missing envFrom secret ${SECRET_NAME} (got: ${HAS_ENVFROM:-none})" >&2
  exit 1
fi
echo "OK: envFrom ${SECRET_NAME} attached"
if ! kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.serviceAccountName}' 2>/dev/null | grep -qx paas-frontend; then
  echo "==> Force serviceAccountName=paas-frontend on deployment/${DEPLOY_NAME}"
  kubectl_patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=json -p='[{"op":"replace","path":"/spec/template/spec/serviceAccountName","value":"paas-frontend"}]'
fi
if [[ "${PAAS_UNPIN_FRONTEND:-}" == "1" ]]; then
  NS_JSON="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
  if [[ -n "${NS_JSON}" && "${NS_JSON}" != "{}" ]]; then
    echo "==> Remove nodeSelector from deployment/${DEPLOY_NAME} (PAAS_UNPIN_FRONTEND=1)"
    kubectl_patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=json \
      -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' 2>/dev/null \
      || kubectl_patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=strategic \
        -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}' || true
  fi
  FPOL="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || true)"
  if [[ "${FPOL}" == "Never" ]]; then
    echo "==> imagePullPolicy Never -> IfNotPresent (PAAS_UNPIN_FRONTEND=1)"
    kubectl_patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' 2>/dev/null || true
  fi
else
  CUR_IMAGE="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ "${CUR_IMAGE}" == *paas-frontend:recovery* || "${CUR_IMAGE}" == docker.io/library/paas-frontend:* ]]; then
    echo "==> Keep master-local image schedule (local image — pin master on env sync)"
    if [[ -f "${SCRIPT_DIR}/lab-frontend-lab-safety.sh" ]]; then
      # shellcheck source=lab-frontend-lab-safety.sh
      source "${SCRIPT_DIR}/lab-frontend-lab-safety.sh"
      ensure_lab_frontend_safety 2>/dev/null || true
    fi
  fi
fi
REPLICAS="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
ROLLOUT_FAILED=0
if [[ "${PAAS_SKIP_ROLLOUT:-}" == "1" ]] || [[ "${REPLICAS}" -eq 0 ]]; then
  echo "==> Skip rollout (replicas=${REPLICAS}); pod will pick up env on next start"
else
  echo "==> Rollout"
  if ! kubectl rollout restart deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}" --request-timeout="${KUBECTL_TIMEOUT}"; then
    echo "WARN: rollout restart patch failed — delete frontend pod"
    kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 \
      --request-timeout="${KUBECTL_TIMEOUT}" --wait=false 2>/dev/null || true
  fi
  if ! kubectl rollout status deployment/"${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s --request-timeout="${KUBECTL_TIMEOUT}"; then
    ROLLOUT_FAILED=1
    FRONTEND_IMAGE="$(kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    echo ""
    echo "WARN: frontend rollout timed out (secret/env may still be updated)."
    echo "  deployment image: ${FRONTEND_IMAGE:-unknown}"
    kubectl get pods -n "${PAAS_NS}" -l app=frontend -o wide 2>/dev/null || true
    kubectl get events -n "${PAAS_NS}" --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' 2>/dev/null | tail -8 || true
    echo ""
    echo "If the new pod is ImagePullBackOff / ErrImageNeverPull (image was pruned from k3s):"
    echo "  bash paas/scripts/lab.sh frontend-force"
    if [[ -f "${SCRIPT_DIR}/lab-frontend-force-recover.sh" ]]; then
      echo "==> Auto-recover frontend (ErrImageNeverPull / rollout timeout)"
      bash "${SCRIPT_DIR}/lab-frontend-force-recover.sh" || true
    fi
  fi
fi
echo "==> Core auth env in pod"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- sh -c '
  for v in JWT_SECRET JENKINS_BASE_URL JENKINS_USERNAME JENKINS_API_TOKEN DATABASE_URL; do
    eval "val=\$$v"
    if [ -n "$val" ]; then echo "$v=set"; else echo "$v=MISSING"; fi
  done
' 2>/dev/null || echo "WARN: could not exec into pod yet — wait for rollout, then re-run"
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
echo "==> Prometheus / Kubernetes in pod"
kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- sh -c '
  for v in KUBERNETES_ENABLED KUBE_CONFIG_PATH PROMETHEUS_BASE_URL PROMETHEUS_PROBE_URL; do
    eval "val=\$$v"
    if [ -n "$val" ]; then echo "$v=$val"; else echo "$v=MISSING"; fi
  done
  if [ -n "$KUBERNETES_SERVICE_HOST" ]; then echo "KUBERNETES_SERVICE_HOST=set"; else echo "KUBERNETES_SERVICE_HOST=MISSING"; fi
  if [ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]; then echo "saToken=mounted"; else echo "saToken=MISSING"; fi
' 2>/dev/null || echo "WARN: could not exec into pod yet"
if grep -qE '^KUBE_CONFIG_PATH=' "${FILTERED}" 2>/dev/null; then
  echo "WARN: KUBE_CONFIG_PATH is set in ${ENV_FILE} — remove it for in-cluster PaaS (breaks cluster UI)."
fi
if ! grep -qE '^SONAR_TOKEN=' "${ENV_FILE}"; then
  echo "WARN: ${ENV_FILE} is missing SONAR_TOKEN — Jenkins Step 5 (Sonar) may skip."
  SECURITY_OK=0
fi
if ! grep -qE '^DEPENDENCY_TRACK_API_KEY=' "${ENV_FILE}"; then
  echo "WARN: ${ENV_FILE} is missing DEPENDENCY_TRACK_API_KEY — Jenkins Step 4 (SBOM/DT) may skip."
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
if [[ "${ROLLOUT_FAILED}" -eq 1 ]]; then
  exit 1
fi
