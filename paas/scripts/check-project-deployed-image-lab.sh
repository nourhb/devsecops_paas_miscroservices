#!/usr/bin/env bash
# Show which image tag is running for a PaaS project namespace (e.g. sanhome).
set -euo pipefail

PROJECT_NAME="${1:-sanhome}"
PAAS_NS="${PAAS_NS:-paas}"

NS=$(kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT namespace FROM \"Project\" WHERE \"projectName\" = '${PROJECT_NAME}' AND \"deletedAt\" IS NULL LIMIT 1;" 2>/dev/null | tr -d ' \r\n')
if [[ -z "${NS}" ]]; then
  NS="${PROJECT_NAME}"
fi

echo "==> Namespace: ${NS}"
kubectl get deploy,po -n "${NS}" -o wide 2>/dev/null || echo "WARN: namespace ${NS} not found"

echo ""
echo "==> Container image(s)"
kubectl get deploy -n "${NS}" -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.spec.containers[0].image}{"\n"}{end}' 2>/dev/null || true

echo ""
echo "==> GitOps values image (if repo cloned on VM)"
GITOPS="${GITOPS_REPO_PATH:-$HOME/gitops}"
VALUES="${GITOPS}/apps/${PROJECT_NAME}/values.yaml"
if [[ -f "${VALUES}" ]]; then
  grep -E 'repository:|tag:|digest:' "${VALUES}" | head -6 || true
else
  echo "    (no ${VALUES} — set GITOPS_REPO_PATH)"
fi
