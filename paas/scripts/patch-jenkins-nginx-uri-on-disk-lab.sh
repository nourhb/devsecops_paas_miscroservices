#!/usr/bin/env bash
# Patch paas-deploy config.xml ON DISK inside the Jenkins pod (works when API/git pull fail).
# Fixes: MissingPropertyException: uri at Step 6 (SPA/Vite nginx try_files in Groovy GString).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
JENKINS_NS="${JENKINS_NS:-cicd}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-jenkins}"
JOB="${JOB_NAME:-paas-deploy}"
CFG="/var/jenkins_home/jobs/${JOB}/config.xml"

find_jenkins_pod() {
  kubectl get pod -n "${JENKINS_NS}" -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

die() { echo "ERROR: $*" >&2; exit 1; }

POD="$(find_jenkins_pod)"
[[ -n "${POD}" ]] || die "no Jenkins pod in ${JENKINS_NS} (kubectl get pods -n ${JENKINS_NS})"

echo "==> Jenkins pod: ${JENKINS_NS}/${POD}"
echo "==> Backup ${CFG}"
kubectl exec -n "${JENKINS_NS}" "${POD}" -c "${JENKINS_CONTAINER}" -- \
  sh -c "test -f '${CFG}' && cp -a '${CFG}' '${CFG}.bak-uri-$(date +%Y%m%d%H%M%S)'" \
  || die "missing ${CFG} — job ${JOB} not found in Jenkins home"

echo "==> Patch unescaped Groovy \$uri in nginx try_files (shell heredoc in old Pipeline script)"
kubectl exec -n "${JENKINS_NS}" "${POD}" -c "${JENKINS_CONTAINER}" -- python3 - "${CFG}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8", errors="replace")
orig = text
# Groovy """ blocks: try_files $uri must be try_files \$uri before shell runs
text = text.replace("try_files $uri $uri/", r"try_files \$uri \$uri/")
text = text.replace("try_files $uri/", r"try_files \$uri/")
# Some copies use $uri/ only in location block
if text == orig and "try_files" in text and "$uri" in text:
    text = re.sub(r"try_files\s+\$uri\s+\$uri/", r"try_files \\$uri \\$uri/", text)
path.write_text(text, encoding="utf-8")
if text == orig:
    if "nginx-conf-writefile-20260611" in text or "writeNginxPaasDefaultConf" in text:
        print("OK: already has writeFile nginx fix")
        sys.exit(0)
    if r"try_files \$uri" in text:
        print("OK: try_files already escaped")
        sys.exit(0)
    print("WARN: no unescaped try_files $uri found — may need full Jenkinsfile sync")
    sys.exit(2)
print("OK: patched try_files $uri → \\$uri in config.xml")
PY

echo "==> Verify on disk"
kubectl exec -n "${JENKINS_NS}" "${POD}" -c "${JENKINS_CONTAINER}" -- sh -c "
  if grep -qF 'writeNginxPaasDefaultConf' '${CFG}' || grep -qF 'nginx-conf-writefile-20260611' '${CFG}' || grep -qF 'try_files \\\$uri' '${CFG}'; then
    echo 'OK: config.xml has nginx uri fix'
  else
    echo 'FAIL: patch did not stick'
    grep -n 'try_files' '${CFG}' | head -3 || true
    exit 1
  fi
"

echo "==> Disable PaaS inline Jenkins overwrite (stale bundled Jenkinsfile)"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -q '^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=' "${ENV_FILE}" 2>/dev/null; then
    sed -i 's|^JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=.*|JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false|' "${ENV_FILE}"
  else
    echo 'JENKINS_SYNC_INLINE_JOB_BEFORE_TRIGGER=false' >> "${ENV_FILE}"
  fi
  if command -v kubectl >/dev/null 2>&1 && kubectl get deployment frontend -n paas >/dev/null 2>&1; then
    ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || true
  fi
fi

echo ""
echo "Done. Trigger Build with Parameters (NOT Replay):"
echo "  http://192.168.56.129:30090/job/${JOB}/build?delay=0sec"
echo "Step 6 should pass. For full security markers also run:"
echo "  bash paas/scripts/force-jenkins-nginx-uri-fix-lab.sh"
