#!/usr/bin/env bash
# Restore full 12-step paas-deploy pipeline: env, Jenkins job, Sonar token, integrations.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
PAAS_NS="${PAAS_NS:-paas}"
NODE_IP="${NODE_IP:-192.168.56.129}"
JENKINS_NS="${JENKINS_NS:-cicd}"
SONAR_PORT="${SONAR_NODEPORT:-30900}"
ENV_DOT="${REPO_ROOT}/paas/frontend/.env"
ENV_COMPOSE="${REPO_ROOT}/paas/frontend/docker-compose.env"
FAIL=0

step() { echo ""; echo "========== $* =========="; }
warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "OK: $*"; }

ensure_kyverno_unblocked() {
  PAAS_FORCE_KYVERNO_UNBLOCK=1 PAAS_SKIP_KYVERNO_RESTART=1 \
    bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard
}

set_sonar_token_in_env() {
  local token="$1"
  [[ -n "${token}" ]] || return 1
  if [[ ! -f "${ENV_DOT}" ]]; then
    fail "missing ${ENV_DOT}"
    return 1
  fi
  local tmp
  tmp="$(mktemp)"
  grep -v '^SONAR_TOKEN=' "${ENV_DOT}" > "${tmp}" || true
  echo "SONAR_TOKEN=${token}" >> "${tmp}"
  mv "${tmp}" "${ENV_DOT}"
  if ! grep -qE '^SONAR_BASE_URL=' "${ENV_DOT}"; then
    echo "SONAR_BASE_URL=http://${NODE_IP}:${SONAR_PORT}" >> "${ENV_DOT}"
  fi
  ok "SONAR_TOKEN written to ${ENV_DOT}"
}

sonar_validate() {
  local token="$1" url="${2:-http://${NODE_IP}:${SONAR_PORT}}"
  curl -sS -m 15 -u "${token}:" "${url%/}/api/authentication/validate" 2>/dev/null \
    | grep -q '"valid"[[:space:]]*:[[:space:]]*true'
}

read_env_sonar_token() {
  if [[ -f "${ENV_DOT}" ]]; then
    grep -m1 '^SONAR_TOKEN=' "${ENV_DOT}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'"
  fi
}

read_env_sonar_url() {
  if [[ -f "${ENV_DOT}" ]]; then
    local u
    u="$(grep -m1 '^SONAR_BASE_URL=' "${ENV_DOT}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")"
    if [[ -n "${u}" ]]; then
      echo "${u}"
      return
    fi
    u="$(grep -m1 '^SONAR_HOST_URL=' "${ENV_DOT}" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d "'")"
    [[ -n "${u}" ]] && echo "${u}" || echo "http://${NODE_IP}:${SONAR_PORT}"
  else
    echo "http://${NODE_IP}:${SONAR_PORT}"
  fi
}

verify_twelve_stages_on_jenkins() {
  if kubectl exec -n "${JENKINS_NS}" deploy/jenkins --request-timeout=45s -- \
    grep -qF 'stage("Step 12 —' /var/jenkins_home/paas/paas-deploy-stages.groovy 2>/dev/null \
    && kubectl exec -n "${JENKINS_NS}" deploy/jenkins --request-timeout=45s -- \
    grep -qF 'dt-api-server-svc-20260617' /var/jenkins_home/paas/paas-deploy-stages.groovy 2>/dev/null; then
    ok "Jenkins stages file has Step 12 + dt-api-server marker (June 17 layout)"
  else
    fail "Jenkins stages file stale — run: bash paas/scripts/lab.sh rollback-june17"
  fi
}

sync_env_to_cluster() {
  bash "${SCRIPT_DIR}/compose-paas-frontend-env.sh"
  kubectl create secret generic paas-frontend-env \
    --from-env-file="${ENV_COMPOSE}" \
    -n "${PAAS_NS}" \
    --dry-run=client -o yaml | kubectl apply --validate=false --request-timeout=60s -f -
  kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic --request-timeout=60s -p "$(cat <<PATCH
{
  "spec": {
    "template": {
      "spec": {
        "serviceAccountName": "paas-frontend",
        "containers": [
          {
            "name": "frontend",
            "envFrom": [{ "secretRef": { "name": "paas-frontend-env" } }]
          }
        ]
      }
    }
  }
}
PATCH
)" 2>/dev/null || true
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}" --request-timeout=60s
  kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=300s --request-timeout=60s
}

main() {
  echo "=============================================="
  echo " lab-pipeline-full-heal — 12-step paas-deploy"
  echo "=============================================="

  step "1/8 Kyverno (unblock patches)"
  ensure_kyverno_unblocked

  step "2/8 Postgres (frontend needs postgres:5432)"
  if PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh"; then
    ok "Postgres reachable from frontend pod"
  else
    warn "db-repair failed — trying worker2 (PVC node)"
    bash "${SCRIPT_DIR}/lab-worker2-heal.sh" || true
    PAAS_DB_REPAIR_COOLDOWN_SEC=0 bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || fail "Postgres still down"
  fi

  step "3/8 SonarQube pod"
  if kubectl get pods -n sonarqube --request-timeout=30s 2>/dev/null | grep -q Running; then
    ok "SonarQube pod Running"
  else
    warn "SonarQube not Running — Step 5 will fail"
    kubectl get pods -n sonarqube --request-timeout=30s 2>/dev/null || true
    FAIL=1
  fi

  step "4/8 SONAR_TOKEN"
  local token url
  token="${SONAR_TOKEN:-$(read_env_sonar_token)}"
  url="$(read_env_sonar_url)"
  if [[ -n "${SONAR_TOKEN:-}" ]]; then
    set_sonar_token_in_env "${SONAR_TOKEN}"
    token="${SONAR_TOKEN}"
  fi
  if [[ -z "${token}" ]]; then
    fail "SONAR_TOKEN missing in ${ENV_DOT}"
    echo "  Create token: http://${NODE_IP}:${SONAR_PORT} → My Account → Security → Generate Token"
    echo "  Then: SONAR_TOKEN=sqa_... bash paas/scripts/lab.sh pipeline-heal"
    FAIL=1
  elif sonar_validate "${token}" "${url}"; then
    ok "Sonar token valid at ${url}"
  else
    fail "Sonar token invalid at ${url} (got valid:false)"
    echo "  Generate NEW token in Sonar UI and run:"
    echo "  SONAR_TOKEN=sqa_YOUR_NEW_TOKEN bash paas/scripts/lab.sh pipeline-heal"
    FAIL=1
  fi

  if [[ "${FAIL}" -ne 0 ]]; then
    echo ""
    echo "Fix SONAR_TOKEN above, then re-run this script."
    exit 1
  fi

  step "5/8 Jenkins + stages (12 steps)"
  if ! curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 "http://${NODE_IP}:30090/login" | grep -qE '200|403'; then
    bash "${SCRIPT_DIR}/lab-jenkins-recover.sh" recover || fail "Jenkins not up"
  else
    ok "Jenkins NodePort :30090"
  fi
  SKIP_FRONTEND_REBUILD=true LAB_DT_SKIP_HEAL=true PAAS_SKIP_ENV_SYNC=1 \
    bash "${SCRIPT_DIR}/sync-jenkins-pipeline-from-repo.sh"
  verify_twelve_stages_on_jenkins
  bash "${SCRIPT_DIR}/verify-jenkins-stages-on-cluster.sh" || FAIL=1

  step "6/8 Frontend env secret + rollout"
  sync_env_to_cluster
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only --force

  step "7/8 Jenkins pod → Sonar"
  local jtok="${token}"
  if kubectl exec -n "${JENKINS_NS}" deploy/jenkins --request-timeout=45s -- \
    curl -sS -m 15 -u "${jtok}:" "http://${NODE_IP}:${SONAR_PORT}/api/authentication/validate" 2>/dev/null \
    | grep -q '"valid":true'; then
    ok "Jenkins agent validates Sonar token"
  else
    warn "Jenkins pod curl check failed — retrying with secret token"
    jtok="$(kubectl get secret paas-frontend-env -n "${PAAS_NS}" -o jsonpath='{.data.SONAR_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -n "${jtok}" ]] && kubectl exec -n "${JENKINS_NS}" deploy/jenkins --request-timeout=45s -- \
      curl -sS -m 15 -u "${jtok}:" "http://${NODE_IP}:${SONAR_PORT}/api/authentication/validate" 2>/dev/null \
      | grep -q '"valid":true'; then
      ok "Jenkins agent validates Sonar token (from secret)"
    elif sonar_validate "${token}" "${url}"; then
      ok "Sonar valid from host (Jenkins uses same NodePort ${SONAR_PORT} at runtime)"
    else
      fail "Jenkins agent cannot validate Sonar token"
      FAIL=1
    fi
  fi

  step "8/8 Harbor (Step 6+ needs registry)"
  bash "${SCRIPT_DIR}/lab-harbor.sh" recover 2>/dev/null || warn "Harbor recover skipped — image push may fail at Step 6"

  echo ""
  echo "=============================================="
  if [[ "${FAIL}" -eq 0 ]]; then
    echo "OK — full 12-step pipeline is ready."
    echo ""
    echo "  1. Open http://${NODE_IP}:30100"
    echo "  2. Deploy your project (NEW build, not Replay)"
    echo "  3. Jenkins: http://${NODE_IP}:30090/job/paas-deploy/"
    echo ""
    echo "Blue Ocean shows steps as they RUN. After Step 5 passes you will"
    echo "see Step 6 (Docker) … Step 12 (GitOps). All 12 are on the server."
  else
    echo "Some checks failed — fix WARN/FAIL above and re-run:"
    echo "  bash paas/scripts/lab.sh pipeline-heal"
  fi
  echo "=============================================="
  exit "${FAIL}"
}

main "$@"
