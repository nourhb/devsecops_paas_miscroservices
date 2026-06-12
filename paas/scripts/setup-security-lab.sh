#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
PAAS_NS="${PAAS_NS:-paas}"

upsert_env() {
  local key="$1" val="$2"
  [[ -f "${ENV_FILE}" ]] || { echo "ERROR: missing ${ENV_FILE}" >&2; exit 1; }
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

svc_url() {
  local ns="$1" svc="$2" port="${3:-}"
  local np=""
  if [[ -n "${port}" ]]; then
    np="$(kubectl get svc -n "${ns}" "${svc}" -o jsonpath="{.spec.ports[?(@.port==${port})].nodePort}" 2>/dev/null || true)"
  fi
  [[ -z "${np}" || "${np}" == "null" ]] && np="$(kubectl get svc -n "${ns}" "${svc}" -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || true)"
  [[ -n "${np}" && "${np}" != "null" ]] && echo "http://${NODE_IP}:${np}"
}

echo "=== 1. Ensure SonarQube + Dependency-Track pods (may take several minutes on first install) ==="
if [[ -x "${SCRIPT_DIR}/check.sh" ]]; then
  AUTO_FIX=1 bash "${SCRIPT_DIR}/check.sh" 2>&1 | tail -30 || true
fi

echo "=== 2. Wire integration URLs + RBAC ==="
ENV_FILE="${ENV_FILE}" NODE_IP="${NODE_IP}" bash "${SCRIPT_DIR}/fix-integrations-lab.sh"

echo "=== 3. Policy engine (Kyverno) ==="
upsert_env POLICY_ENGINE "kyverno"
upsert_env KYVERNO_POLICIES_ENABLED "true"
if command -v helm >/dev/null 2>&1; then
  bash "${SCRIPT_DIR}/apply-kyverno-policies-lab.sh" || echo "WARN: Kyverno install/apply failed — run: bash paas/scripts/ensure-kyverno-lab.sh"
else
  echo "WARN: helm missing — cannot install Kyverno; set POLICY_ENGINE=none for demo"
fi

echo "=== 4. Jenkins pipeline: full security stages (not fast pipeline) ==="
upsert_env JENKINS_PAAS_FAST_PIPELINE "false"
upsert_env JENKINS_SH_KEEPALIVE "true"
upsert_env JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER "false"

echo "=== 5. SonarQube API token (fixes UI HTTP 401) ==="
SONAR_BASE="$(grep '^SONAR_BASE_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
[[ -z "${SONAR_BASE}" ]] && SONAR_BASE="$(svc_url sonarqube sonarqube-sonarqube 9000)"
if [[ -n "${SONAR_BASE}" ]]; then
  upsert_env SONAR_BASE_URL "${SONAR_BASE}"
  CUR_TOKEN="$(grep '^SONAR_TOKEN=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  if [[ -z "${CUR_TOKEN}" || "${CUR_TOKEN}" == *"your-sonar"* || "${CUR_TOKEN}" == "paste"* ]]; then
    SONAR_USER="${SONAR_ADMIN_USER:-admin}"
    SONAR_PASS="${SONAR_ADMIN_PASSWORD:-admin}"
    NEW_TOKEN="$(curl -fsS -u "${SONAR_USER}:${SONAR_PASS}" -X POST \
      "${SONAR_BASE%/}/api/user_tokens/generate?name=paas-lab" 2>/dev/null \
      | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || true)"
    if [[ -n "${NEW_TOKEN}" ]]; then
      upsert_env SONAR_TOKEN "${NEW_TOKEN}"
      echo "OK: SONAR_TOKEN generated via API"
    else
      echo "WARN: Could not auto-generate Sonar token."
      echo "      Open ${SONAR_BASE} → My Account → Security → Generate Token"
      echo "      Set SONAR_TOKEN=... in ${ENV_FILE}"
    fi
  else
    SONAR_VALID="$(curl -sS -m 12 -u "${CUR_TOKEN}:" "${SONAR_BASE%/}/api/authentication/validate" 2>/dev/null || true)"
    if echo "${SONAR_VALID}" | grep -q '"valid":true'; then
      echo "OK: SONAR_TOKEN valid"
    else
      echo "WARN: SONAR_TOKEN rejected (${SONAR_VALID:-curl failed}) — regenerating"
      REGENERATE_SONAR_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-sonar-token-lab.sh" || \
        echo "      Manual: ${SONAR_BASE} → My Account → Security → Generate Token"
    fi
  fi
else
  echo "WARN: SonarQube not reachable — run: AUTO_FIX=1 bash paas/scripts/check.sh"
fi

echo "=== 6. Dependency-Track API key ==="
DT_BASE="$(grep '^DEPENDENCY_TRACK_BASE_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
[[ -z "${DT_BASE}" ]] && DT_BASE="$(svc_url dependency-track dtrack-dependency-track-api-server 8080)"
[[ -z "${DT_BASE}" ]] && DT_BASE="$(svc_url security dependency-track-api-server 8080)"
if [[ -n "${DT_BASE}" ]]; then
  upsert_env DEPENDENCY_TRACK_BASE_URL "${DT_BASE}"
  CUR_DT="$(grep '^DEPENDENCY_TRACK_API_KEY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
  DT_HTTP="000"
  if [[ -n "${CUR_DT}" && "${CUR_DT}" != *"your-dependency"* ]]; then
    DT_HTTP="$(curl -sS -m 15 -o /dev/null -w '%{http_code}' -H "X-Api-Key: ${CUR_DT}" "${DT_BASE%/}/api/v1/project" 2>/dev/null || echo 000)"
  fi
  if [[ -z "${CUR_DT}" || "${CUR_DT}" == *"your-dependency"* || "${DT_HTTP}" != "200" ]]; then
    echo "==> Auto-generate DEPENDENCY_TRACK_API_KEY (HTTP ${DT_HTTP})"
    REGENERATE_DT_SKIP_DEPLOY=1 bash "${SCRIPT_DIR}/regenerate-dependency-track-api-key-lab.sh" || {
      echo "WARN: could not auto-generate API key"
      echo "      UI: $(svc_url dependency-track dtrack-dependency-track-frontend 8080 2>/dev/null \
        || svc_url security dependency-track-frontend 8080 2>/dev/null \
        || echo dependency-track) → Administration → Access Management → Teams → API Keys"
    }
  else
    echo "OK: DEPENDENCY_TRACK_API_KEY valid (HTTP 200)"
  fi
else
  echo "WARN: Dependency-Track API not found"
fi

echo "=== 7. Cosign (image signing for UI + Kyverno) ==="
upsert_env COSIGN_ALLOW_INSECURE_REGISTRY "true"
upsert_env COSIGN_PASSWORD ""
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
mkdir -p "${KEYDIR}"
if command -v cosign >/dev/null 2>&1; then
  if [[ ! -f "${KEYDIR}/cosign.key" ]]; then
    echo "Generating Cosign key pair (empty COSIGN_PASSWORD for lab Jenkins Step 9)…"
    COSIGN_PASSWORD="" cosign generate-key-pair --output-key-prefix "${KEYDIR}/cosign" 2>/dev/null || true
  fi
fi
if [[ -f "${KEYDIR}/cosign.pub" ]]; then
  python3 - "${KEYDIR}/cosign.pub" "${ENV_FILE}" <<'PY'
import pathlib, re, sys
pub_path, env_path = sys.argv[1], sys.argv[2]
pem = pathlib.Path(pub_path).read_text().strip()
quoted = '"' + pem.replace("\n", "\\n") + '"'
text = pathlib.Path(env_path).read_text(encoding="utf-8")
key = "COSIGN_PUBLIC_KEY="
if re.search(rf"^{re.escape(key)}", text, re.M):
    text = re.sub(rf"^{re.escape(key)}.*$", f"{key}{quoted}", text, flags=re.M)
else:
    text = text.rstrip() + f"\n{key}{quoted}\n"
pathlib.Path(env_path).write_text(text, encoding="utf-8")
PY
  if [[ -f "${KEYDIR}/cosign.key" ]]; then
    python3 - "${KEYDIR}/cosign.key" "${ENV_FILE}" <<'PY'
import pathlib, re, sys
key_path, env_path = sys.argv[1], sys.argv[2]
pem = pathlib.Path(key_path).read_text().strip()
quoted = '"' + pem.replace("\n", "\\n") + '"'
text = pathlib.Path(env_path).read_text(encoding="utf-8")
k = "COSIGN_PRIVATE_KEY="
if re.search(rf"^{re.escape(k)}", text, re.M):
    text = re.sub(rf"^{re.escape(k)}.*$", f"{k}{quoted}", text, flags=re.M)
else:
    text = text.rstrip() + f"\n{k}{quoted}\n"
pathlib.Path(env_path).write_text(text, encoding="utf-8")
PY
  fi
  echo "OK: Cosign keys in ${ENV_FILE} (private key passed to Jenkins on each build trigger)"
  if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
    bash "${SCRIPT_DIR}/apply-kyverno-policies-lab.sh" 2>/dev/null || true
    echo "OK: Kyverno require-signed-images updated with lab public key"
  fi
else
  echo "WARN: No ${KEYDIR}/cosign.pub — install cosign and re-run, or set keys manually"
fi
SONAR_BASE_NOW="$(grep '^SONAR_BASE_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d "'\"" || true)"
[[ -n "${SONAR_BASE_NOW}" ]] && upsert_env SONAR_HOST_URL "${SONAR_BASE_NOW}"

echo "=== 8. Sync frontend + Jenkins job (full parameters: SONAR_*, DEPENDENCY_TRACK_*) ==="
ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a
bash "${SCRIPT_DIR}/fix-jenkins-paas-deploy-pipeline-lab.sh" || \
  echo "WARN: fix-jenkins failed — run: python3 paas/scripts/create_jenkins_paas_deploy_job.py --force --force-full"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full || true
bash "${SCRIPT_DIR}/sync-cosign-keys-lab.sh" 2>/dev/null || true
bash "${SCRIPT_DIR}/mount-cosign-pub-frontend-lab.sh" 2>/dev/null || true
bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh" 2>/dev/null || true

echo "=== 9. Cosign-sign images already deployed (Security UI: signed) ==="
if [[ -x "${SCRIPT_DIR}/sign-all-deployed-paas-images-lab.sh" ]]; then
  bash "${SCRIPT_DIR}/sign-all-deployed-paas-images-lab.sh" || echo "WARN: sign-all failed — run finalize-devsecops-security-lab.sh"
elif [[ -x "${SCRIPT_DIR}/finalize-devsecops-security-lab.sh" ]]; then
  SKIP_FRONTEND_REBUILD=1 SIGN_IMAGES=1 bash "${SCRIPT_DIR}/finalize-devsecops-security-lab.sh" 2>/dev/null || \
    bash "${SCRIPT_DIR}/sign-latest-jenkins-paas-image-lab.sh" lastBuild || true
else
  echo "WARN: sign-all-deployed-paas-images-lab.sh missing — git pull then re-run setup-security-lab.sh"
fi

echo ""
echo "=== 10. Verify from frontend pod ==="
set -a
# shellcheck disable=SC1090
source "${ENV_FILE}" 2>/dev/null || true
set +a
kubectl exec -n "${PAAS_NS}" deploy/frontend -- node paas/frontend/scripts/check-integrations.mjs 2>/dev/null | \
  grep -iE 'Sonar|Dependency-Track|Trivy|Cosign' || echo "(run check-integrations after deploy if script missing in image)"

echo ""
echo "=== Done — security data flow ==="
echo "  Pipeline Step 4 → SBOM → Dependency-Track (dashboard DT bars)"
echo "  Pipeline Step 5 → SonarQube analysis (quality gate / sonar charts)"
echo "  Pipeline Step 9 → Cosign sign image (signed / deployment allowed)"
echo "  Trivy → scans image on Harbor / TRIVY_BASE_URL (trivy counts)"
echo ""
echo "Run a NEW Jenkins build per project (JENKINS_PAAS_FAST_PIPELINE=false), wait for SUCCESS, refresh Security page."
echo "  AUTO_FIX=1 bash paas/scripts/verify-security-pipeline-lab.sh"
echo "  PROJECT_ID=<uuid> python3 paas/scripts/trigger-paas-deploy-lab.py"
echo "Sonar UI: ${SONAR_BASE:-http://${NODE_IP}:30900}"
echo "Harbor Trivy in Security UI needs frontend rebuild after git pull: REBUILD_FRONTEND=1 bash paas/scripts/fix-security-all-projects-lab.sh"
