#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lab-kube-env.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"

echo "=============================================="
echo " lab-enable-full-pipeline (Steps 7–8, 10–11)"
echo "=============================================="

cd "${REPO_ROOT}"

echo "==> 0/6 Wait for Kubernetes API"
if ! lab_k8s_api_ready; then
  for i in $(seq 1 36); do
    sleep 5
    lab_k8s_api_ready && break
    [[ "${i}" -eq 36 ]] || continue
    echo "ERROR: Kubernetes API not reachable (TLS timeout / k3s down)." >&2
    echo "  Fix: sudo systemctl restart k3s && sleep 90" >&2
    echo "  Or:  bash paas/scripts/lab.sh start" >&2
    echo "  Then: kubectl get nodes && kubectl get deploy -n cicd" >&2
    exit 1
  done
fi
ok_api() { echo "OK: Kubernetes API ready"; }
ok_api

echo "==> 1/6 Jenkins agent tools (helm + crane cache)"
bash "${SCRIPT_DIR}/lab-jenkins-agent-tools.sh"

echo "==> 2/6 kubectl + ZAP RBAC in Jenkins pod"
bash "${SCRIPT_DIR}/lab-jenkins-zap-tools.sh"

echo "==> 3/6 Artifactory (Step 8)"
bash "${SCRIPT_DIR}/bootstrap-artifactory-lab.sh"

echo "==> 4/6 ZAP_TARGET_URL + Harbor Helm OCI env"
bash "${SCRIPT_DIR}/bootstrap-integrations-lab.sh" || true
for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
  [[ -f "${f}" ]] || continue
  grep -q '^HELM_OCI_INSECURE=' "${f}" 2>/dev/null || echo 'HELM_OCI_INSECURE=true' >> "${f}"
  grep -q '^HELM_OCI_PLAIN_HTTP=' "${f}" 2>/dev/null || echo 'HELM_OCI_PLAIN_HTTP=true' >> "${f}"
  sed -i 's|^HELM_OCI_INSECURE=.*|HELM_OCI_INSECURE=true|' "${f}" 2>/dev/null || true
  sed -i 's|^HELM_OCI_PLAIN_HTTP=.*|HELM_OCI_PLAIN_HTTP=true|' "${f}" 2>/dev/null || true
done
if ! grep -qE '^ZAP_TARGET_URL=.+' "${ENV_FILE}" 2>/dev/null; then
  app_url="$(grep -m1 '^APP_BASE_URL=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
  if [[ -n "${app_url}" ]]; then
    for f in "${ENV_FILE}" "${REPO_ROOT}/paas/frontend/.env"; do
      [[ -f "${f}" ]] || continue
      if grep -q '^ZAP_TARGET_URL=' "${f}"; then
        sed -i "s|^ZAP_TARGET_URL=.*|ZAP_TARGET_URL=${app_url}|" "${f}"
      else
        echo "ZAP_TARGET_URL=${app_url}" >> "${f}"
      fi
    done
    echo "OK: ZAP_TARGET_URL=${app_url}"
  else
    echo "WARN: set ZAP_TARGET_URL in ${ENV_FILE} (public app URL for DAST)"
  fi
fi

echo "==> 5/6 CPS-split Jenkins stages (ensureHelmTool + stub chart + ZAP kubectl)"
bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"

echo "==> 6/6 Sync env + Jenkins params (do NOT touch June 17 job wrapper)"
set -a
source "${ENV_FILE}" 2>/dev/null || true
set +a
PAAS_SKIP_ROLLOUT="${PAAS_SKIP_ROLLOUT:-1}" ENV_FILE="${ENV_FILE}" \
  bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh" 2>/dev/null || bash "${SCRIPT_DIR}/compose-paas-frontend-env.sh"
python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --params-only --force

echo ""
echo "=============================================="
echo " OK — full pipeline prerequisites installed"
echo " Trigger a new paas-deploy build from the PaaS UI or Jenkins."
echo "=============================================="
