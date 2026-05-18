#!/usr/bin/env bash
# One-shot: build chart (from test-app in gitops clone), push, Argo sync, verify.
# Requires: GITHUB_TOKEN (ghp_...) with repo push to nourhb/gitops
# Usage: GITHUB_TOKEN=ghp_xxx bash paas/scripts/deploy-simple-app-all-in-one.sh 99
set -euo pipefail

BUILD_NUM="${1:-99}"
NODE_IP="${NODE_IP:-192.168.56.129}"
INGRESS_PORT="${INGRESS_PORT:-30659}"
GITOPS_DIR="${GITOPS_DIR:-${HOME}/gitops}"
DEST="${GITOPS_DIR}/apps/simple-app"
SRC_TEST="${GITOPS_DIR}/apps/test-app"
NS="simple-app"
APP_URL="http://simple-app.${NODE_IP}.nip.io:${INGRESS_PORT}/"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${GITHUB_TOKEN:-}" ]] || die "Set GITHUB_TOKEN (GitHub PAT with repo scope). Password login does not work."

if [[ ! -d "${GITOPS_DIR}/.git" ]]; then
  git clone https://github.com/nourhb/gitops.git "${GITOPS_DIR}"
fi

[[ -f "${SRC_TEST}/Chart.yaml" ]] || die "Missing ${SRC_TEST}/Chart.yaml in gitops clone"

echo "=== [1/5] Build simple-app chart from apps/test-app ==="
rm -rf "${DEST}"
cp -a "${SRC_TEST}" "${DEST}"
find "${DEST}" -type f \( -name '*.yaml' -o -name '*.tpl' \) -exec sed -i 's/test-app/simple-app/g' {} +

cat > "${DEST}/values.yaml" <<EOF
image:
  repository: 192.168.56.129:30002/paas/simple-app
  tag: "${BUILD_NUM}"
  digest: ""
  pullPolicy: IfNotPresent

imagePullSecrets:
  - name: harbor-regcred

service:
  targetPort: 3000

resources:
  limits:
    cpu: "500m"
    memory: "512Mi"
  requests:
    cpu: "100m"
    memory: "128Mi"

env: []

ingress:
  enabled: true
  className: traefik
  hosts:
    - host: simple-app.${NODE_IP}.nip.io
  tls: []
EOF

echo "=== [2/5] Namespace (harbor-regcred must already exist in ${NS}) ==="
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl get secret harbor-regcred -n "$NS" >/dev/null 2>&1 || \
  echo "WARN: harbor-regcred missing in ${NS} — copy from paas ns if ImagePullBackOff"

echo "=== [3/5] Push to GitHub ==="
cd "${GITOPS_DIR}"
git add apps/simple-app
if git diff --cached --quiet; then
  echo "No git changes to push."
else
  git commit -m "Add simple-app Helm chart from test-app (image tag ${BUILD_NUM})"
  git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
fi

echo "=== [4/5] Argo CD sync ==="
argocd app sync paas-simple-app --force
sleep 8

echo "=== [5/5] Verify ==="
argocd app get paas-simple-app 2>/dev/null | grep -E 'Sync Status|Revision' || true
kubectl get pods,svc,ingress -n "$NS"
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" || echo "000")"
echo "HTTP ${HTTP_CODE}"

if kubectl get pods -n "$NS" --field-selector=status.phase=Running 2>/dev/null | grep -q Running; then
  echo "OK"
else
  kubectl describe pod -n "$NS" -l app.kubernetes.io/name=simple-app 2>/dev/null | tail -30 || true
  exit 1
fi
