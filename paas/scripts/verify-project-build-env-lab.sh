#!/usr/bin/env bash
# Diagnose why a project's NEXT_PUBLIC_* / Firebase env is not in the deployed bundle.
set -euo pipefail

PROJECT_NAME="${1:-sanhome}"
PAAS_NS="${PAAS_NS:-paas}"
JENKINS_JOB="${JENKINS_DEPLOY_JOB_NAME:-paas-deploy}"
ENV_FILE="${ENV_FILE:-$(cd "$(dirname "$0")/../frontend" && pwd)/docker-compose.env}"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> Project build env in Postgres (${PROJECT_NAME})"
ROW=$(kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT id || '|' || COALESCE(length(\"buildEnv\"::text)::text, '0') || '|' || CASE WHEN \"buildEnv\" IS NULL THEN 'null' WHEN \"buildEnv\"::text LIKE '%__enc%' THEN 'encrypted' ELSE 'plain' END FROM \"Project\" WHERE \"projectName\" = '${PROJECT_NAME}' AND \"deletedAt\" IS NULL LIMIT 1;" 2>/dev/null || true)
if [[ -z "${ROW}" ]]; then
  die "No project named ${PROJECT_NAME} in database"
fi
IFS='|' read -r PROJECT_ID BUILD_ENV_LEN BUILD_ENV_KIND <<< "${ROW}"
echo "    id=${PROJECT_ID} buildEnv=${BUILD_ENV_KIND} bytes=${BUILD_ENV_LEN}"

if [[ "${BUILD_ENV_KIND}" == "null" || "${BUILD_ENV_LEN}" == "0" ]]; then
  echo ""
  echo "FIX: PaaS UI → Projects → ${PROJECT_NAME} → Edit → Application environment (.env)"
  echo "     Paste NEXT_PUBLIC_FIREBASE_* lines, Save, then Deploy (full Jenkins build)."
  exit 1
fi

if [[ -f "${ENV_FILE}" ]]; then
  JWT_LEN=$(grep -E '^JWT_SECRET=' "${ENV_FILE}" | head -1 | cut -d= -f2- | tr -d '\r' | wc -c || echo 0)
  echo "==> JWT_SECRET in ${ENV_FILE}: length=$((JWT_LEN - 1)) (need >= 32 for decrypt)"
else
  echo "WARN: ${ENV_FILE} not found"
fi

echo "==> Frontend pod can decrypt (dry-run via API project fetch)"
echo "    Open Edit project in UI — if textarea is empty but buildEnv is encrypted, JWT_SECRET changed since save."

echo "==> Last Jenkins ${JENKINS_JOB} console (env lines)"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
JENKINS_NS="${JENKINS_NS:-jenkins}"
JENKINS_POD=$(kubectl get pods -n "${JENKINS_NS}" -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${JENKINS_POD}" ]]; then
  LAST=$(kubectl exec -n "${JENKINS_NS}" "${JENKINS_POD}" -- \
    sh -c "wget -qO- --auth-no-challenge --user=\${JENKINS_USER:-admin} --password=\${JENKINS_PASS:-admin} \
    http://127.0.0.1:8080/job/${JENKINS_JOB}/lastBuild/consoleText 2>/dev/null | tail -n 400" 2>/dev/null || true)
  if [[ -n "${LAST}" ]]; then
    echo "${LAST}" | grep -E '\[env\]|\[build-env\]|PROJECT_BUILD_ENV|next.config|verify OK|verify ERROR' || echo "    (no [env] lines — job may be old or env never sent)"
  fi
else
  echo "    (jenkins pod not found in ${JENKINS_NS})"
fi

echo ""
echo "==> Running pod image (cluster)"
NS=$(kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT namespace FROM \"Project\" WHERE id = '${PROJECT_ID}';" 2>/dev/null | tr -d ' ')
if [[ -n "${NS}" ]]; then
  kubectl get deploy -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{" image="}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true
fi

echo ""
echo "Required after code fixes:"
echo "  git pull && bash paas/scripts/deploy-paas-frontend-k8s.sh && bash paas/scripts/fix-jenkins-paas-deploy-pipeline-lab.sh"
echo "Then: Edit ${PROJECT_NAME} → save .env → Deploy → Jenkins must show [env] verify OK"
