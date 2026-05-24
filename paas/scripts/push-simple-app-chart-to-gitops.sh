#!/usr/bin/env bash
set -euo pipefail

BUILD_NUM="${1:-99}"
GITOPS_DIR="${2:-${HOME}/gitops}"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHART_SRC="${REPO_ROOT}/paas/gitops/apps/simple-app"
DEST="${GITOPS_DIR}/apps/simple-app"

if [[ ! -f "${CHART_SRC}/Chart.yaml" ]]; then
  echo "ERROR: chart missing at ${CHART_SRC}/Chart.yaml — git pull devsecops_paas_miscroservices first."
  exit 1
fi

NS="simple-app"
HARBOR_NS="${HARBOR_NS:-paas}"
echo "=== Namespace ${NS} + Harbor pull secret ==="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
if kubectl get secret harbor-regcred -n "$HARBOR_NS" >/dev/null 2>&1; then
  kubectl get secret harbor-regcred -n "$HARBOR_NS" -o yaml \
    | sed "s/namespace: ${HARBOR_NS}/namespace: ${NS}/" \
    | kubectl apply -f -
fi

if [[ ! -d "${GITOPS_DIR}/.git" ]]; then
  echo "=== Cloning nourhb/gitops into ${GITOPS_DIR} ==="
  git clone https://github.com/nourhb/gitops.git "${GITOPS_DIR}"
fi

echo "=== Sync chart → ${DEST} ==="
mkdir -p "${DEST}"
rsync -a --delete \
  --exclude '.git' \
  "${CHART_SRC}/" "${DEST}/"

if command -v sed >/dev/null; then
  sed -i "s/^  tag:.*/  tag: \"${BUILD_NUM}\"/" "${DEST}/values.yaml" 2>/dev/null || \
    sed -i '' "s/^  tag:.*/  tag: \"${BUILD_NUM}\"/" "${DEST}/values.yaml"
fi

echo "=== Git diff (apps/simple-app) ==="
cd "${GITOPS_DIR}"
git status --short apps/simple-app
git diff --stat apps/simple-app || true

echo ""
echo "Files that will be in Git:"
find apps/simple-app -type f | sort

if [[ "${PUSH_YES:-}" == "1" ]]; then
  ans=y
else
  read -r -p "Commit and push to origin main? [y/N] " ans
fi
if [[ "${ans,,}" != "y" ]]; then
  echo "Stopped. Push manually:"
  echo "  cd ${GITOPS_DIR} && git add apps/simple-app && git commit -m 'Add simple-app Helm chart (tag ${BUILD_NUM})' && git push"
  exit 0
fi

git add apps/simple-app
git commit -m "Add simple-app Helm chart (image tag ${BUILD_NUM})"
git push origin main

echo ""
echo "=== Done. On cluster run (one command per line): ==="
echo "argocd app sync paas-simple-app --force"
echo "argocd app get paas-simple-app | grep -E 'Sync Status|Revision'"
echo "kubectl get pods,svc,ingress -n simple-app"
echo "curl -sS -o /dev/null -w '%{http_code}\\n' http://simple-app.192.168.56.129.nip.io:30659/"
