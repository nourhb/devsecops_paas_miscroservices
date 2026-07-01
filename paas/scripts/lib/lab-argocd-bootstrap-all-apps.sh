#!/usr/bin/env bash
# Register GitOps repo in Argo CD and create an Application per project under ~/gitops/apps/*.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
ARGOCD_NS="${ARGOCD_NS:-argocd}"
ARGOCD_APP_PREFIX="${ARGOCD_APP_PREFIX:-paas}"
GITOPS="${GITOPS:-${HOME}/gitops}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

source "${SCRIPT_DIR}/gitops-lab-lib.sh"

read_env() {
  local key="$1" default="$2"
  local v=""
  if [[ -f "${ENV_FILE}" ]]; then
    v="$(grep -E "^${key}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  fi
  printf '%s' "${v:-$default}"
}

GITOPS_REPO_URL="$(read_env GITOPS_REPO_URL https://github.com/nourhb/gitops)"
GITOPS_BRANCH="$(read_env GITOPS_DEFAULT_BRANCH main)"
GITOPS_TOKEN="$(read_env GITOPS_REPO_TOKEN "")"
DEST_SERVER="$(read_env ARGOCD_DEST_SERVER https://kubernetes.default.svc)"

if ! kubectl get crd applications.argoproj.io >/dev/null 2>&1; then
  echo "ERROR: Argo CD Application CRD missing — run: bash paas/scripts/lib/lab-install-argocd-now.sh" >&2
  exit 1
fi

echo "==> Register GitOps repository in Argo CD"
if [[ -n "${GITOPS_TOKEN}" ]]; then
  kubectl create secret generic gitops-github-repo -n "${ARGOCD_NS}" \
    --from-literal=type=git \
    --from-literal=url="${GITOPS_REPO_URL}" \
    --from-literal=username=git \
    --from-literal=password="${GITOPS_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl label secret gitops-github-repo -n "${ARGOCD_NS}" \
    argocd.argoproj.io/secret-type=repository --overwrite >/dev/null
  echo "OK: repository secret gitops-github-repo"
else
  echo "WARN: GITOPS_REPO_TOKEN unset — public repo only or manual Argo repo config" >&2
fi

AUTH_URL=""
[[ -n "${GITOPS_TOKEN}" ]] && AUTH_URL="https://${GITOPS_TOKEN}@github.com/nourhb/gitops.git"
gitops_ensure_on_main "${GITOPS}" "${GITOPS_BRANCH}" "${AUTH_URL}"
gitops_fetch_origin "${GITOPS}" "${GITOPS_BRANCH}" "${AUTH_URL}"

echo "==> Create / sync Argo CD Applications from ${GITOPS}/apps/*"
created=0
for app_dir in "${GITOPS}/apps"/*; do
  [[ -d "${app_dir}" ]] || continue
  project="$(basename "${app_dir}")"
  [[ -f "${app_dir}/values.yaml" ]] || continue
  app_name="${ARGOCD_APP_PREFIX}-${project}"
  dest_ns="${project}"
  chart_path="apps/${project}"
  if kubectl get application "${app_name}" -n "${ARGOCD_NS}" >/dev/null 2>&1; then
    echo "  exists: ${app_name}"
    kubectl annotate application "${app_name}" -n "${ARGOCD_NS}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
    continue
  fi
  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${ARGOCD_NS}
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: ${GITOPS_REPO_URL}
    path: ${chart_path}
    targetRevision: ${GITOPS_BRANCH}
  destination:
    server: ${DEST_SERVER}
    namespace: ${dest_ns}
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
EOF
  echo "  created: ${app_name} → ${chart_path} (ns ${dest_ns})"
  created=$((created + 1))
done

echo "==> Trigger hard refresh on all paas-* applications"
for app in $(kubectl get applications -n "${ARGOCD_NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  [[ "${app}" == ${ARGOCD_APP_PREFIX}-* ]] || continue
  kubectl annotate application "${app}" -n "${ARGOCD_NS}" argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
  kubectl patch application "${app}" -n "${ARGOCD_NS}" --type merge -p '{
    "operation": {
      "initiatedBy": {"username": "lab-bootstrap"},
      "sync": {
        "revision": "HEAD",
        "prune": false,
        "syncStrategy": {"apply": {"force": true}}
      }
    }
  }' >/dev/null 2>&1 || true
done

echo "OK: ${created} new Application(s); Argo CD will reconcile all projects from GitHub GitOps"
