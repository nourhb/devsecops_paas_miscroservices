#!/usr/bin/env bash
# Final lab path: Jenkins push → verify Harbor manifest → GitOps tag → Argo → running app.
#
# Prerequisites:
#   - Harbor registry pod 2/2 Running (kubectl get pods -n harbor -l component=registry)
#   - Jenkins build SUCCESS with: PAAS_ARTIFACT_IMAGE=192.168.56.129:30002/paas/simple-app:<BUILD>
#
# Usage:
#   export GITHUB_TOKEN=ghp_...
#   bash paas/scripts/final-deploy-simple-app-lab.sh <BUILD_NUMBER>
#
# Optional: wipe ghost metadata before Jenkins push (no blobs on disk):
#   PURGE_HARBOR_REPO=1 bash paas/scripts/final-deploy-simple-app-lab.sh <BUILD_NUMBER>
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

BUILD="${1:-}"
if [[ -z "$BUILD" ]]; then
  die "Usage: $0 <jenkins-build-number>
Example: $0 103
Get NNN from Jenkins: PAAS_ARTIFACT_IMAGE=192.168.56.129:30002/paas/simple-app:NNN"
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  die "BUILD must be digits only (got: ${BUILD}). Example: $0 103 — do not type <BUILD_NUMBER>"
fi
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_PORT:-30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
IMAGE_REPO="${IMAGE_REPO:-${NODE_IP}:${HARBOR_PORT}/paas/simple-app}"
GITOPS_DIR="${GITOPS_DIR:-${HOME}/gitops}"
NS="simple-app"
APP_URL="http://simple-app.${NODE_IP}.nip.io:30659/"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/harbor-manifest-check.sh
source "${SCRIPT_DIR}/lib/harbor-manifest-check.sh"

[[ -n "$BUILD" ]] || die "Usage: $0 <jenkins-build-number>   (from PAAS_ARTIFACT_IMAGE in Jenkins console)"
[[ -n "${GITHUB_TOKEN:-}" ]] || die "Set GITHUB_TOKEN (GitHub PAT with repo write)"

command -v curl >/dev/null || die "curl required"
command -v kubectl >/dev/null || die "kubectl required"

echo "=== [1/7] Harbor registry healthy ==="
kubectl get pods -n harbor -l app=harbor,component=registry -o wide | grep -v NAME | grep -q Running || \
  die "harbor-registry not Running. Fix Harbor before this script."
V2_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -I "http://${NODE_IP}:${HARBOR_PORT}/v2/")"
[[ "$V2_CODE" == "401" || "$V2_CODE" == "200" ]] || die "Harbor /v2/ returned HTTP ${V2_CODE} (expected 401 or 200)"

if [[ "${PURGE_HARBOR_REPO:-}" == "1" ]]; then
  echo "=== [2/7] Purge ghost simple-app metadata in Harbor ==="
  curl -sS -o /dev/null -w "DELETE repo HTTP %{http_code}\n" -X DELETE \
    -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "http://${NODE_IP}:${HARBOR_PORT}/api/v2.0/projects/paas/repositories/simple-app" || true
  sleep 3
else
  echo "=== [2/7] Skip Harbor purge (set PURGE_HARBOR_REPO=1 to delete ghost tags) ==="
fi

echo "=== [3/7] Verify image exists in Harbor (OCI index–aware) ==="
HARBOR_HOST="${NODE_IP}:${HARBOR_PORT}"
MAN_CODE="$(harbor_manifest_http_code "${HARBOR_HOST}" "paas/simple-app" "${BUILD}" "${HARBOR_USER}" "${HARBOR_PASS}")"
echo "MAN tag ${BUILD} → HTTP ${MAN_CODE}"
if [[ "$MAN_CODE" != "200" && "$MAN_CODE" != "301" ]]; then
  if harbor_image_pullable "${IMAGE_REPO}:${BUILD}" "${HARBOR_USER}" "${HARBOR_PASS}"; then
    echo "docker pull ${IMAGE_REPO}:${BUILD} → OK (registry has image; curl needed OCI Accept)"
  else
    die "Image ${IMAGE_REPO}:${BUILD} not pullable (MAN HTTP ${MAN_CODE}).
Run Jenkins paas-deploy for simple-app first. In the console confirm:
  PAAS_ARTIFACT_IMAGE=${IMAGE_REPO}:${BUILD}
  crane push finished without error
Then re-run: $0 ${BUILD}"
  fi
fi

echo "=== [4/7] Update GitOps values.yaml tag=${BUILD} ==="
[[ -d "${GITOPS_DIR}/.git" ]] || git clone https://github.com/nourhb/gitops.git "${GITOPS_DIR}"
VALUES="${GITOPS_DIR}/apps/simple-app/values.yaml"
[[ -f "$VALUES" ]] || die "Missing ${VALUES}"
sed -i "s/^  tag:.*/  tag: \"${BUILD}\"/" "$VALUES"
grep -q "runAsNonRoot: false" "${GITOPS_DIR}/apps/simple-app/templates/deployment.yaml" 2>/dev/null || \
  sed -i 's/runAsNonRoot: true/runAsNonRoot: false/g' "${GITOPS_DIR}/apps/simple-app/templates/deployment.yaml" 2>/dev/null || true

cd "${GITOPS_DIR}"
git add apps/simple-app/values.yaml apps/simple-app/templates/deployment.yaml 2>/dev/null || git add apps/simple-app/values.yaml
git diff --cached --quiet && echo "GitOps tag already ${BUILD}" || git commit -m "chore(simple-app): deploy image tag ${BUILD}"
git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main

echo "=== [5/7] Argo CD sync ==="
if command -v argocd >/dev/null; then
  argocd app sync paas-simple-app --force || true
else
  echo "WARN: argocd CLI not found — sync from UI or install argocd"
fi

echo "=== [6/7] Cluster pull + import (workers often lack HTTP Harbor config) ==="
bash "${SCRIPT_DIR}/fix-simple-app-imagepull-lab.sh" "${BUILD}"

echo "=== [7/7] Verify ==="
kubectl get pods -n "$NS" -o wide
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" 2>/dev/null || true)"
HTTP_CODE="${HTTP_CODE:-000}"
echo "App URL: ${APP_URL}"
echo "HTTP ${HTTP_CODE}"
kubectl get pods -n "$NS" | grep -q "1/1.*Running" && [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "304" ]] && \
  echo "OK: simple-app is up." || \
  die "Pod or HTTP check failed. kubectl describe pod -n ${NS} -l app.kubernetes.io/name=simple-app | tail -20"
