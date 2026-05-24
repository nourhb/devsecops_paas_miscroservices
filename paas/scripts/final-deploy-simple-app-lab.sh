#!/usr/bin/env bash
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

BUILD="${1:-}"
if [[ -z "$BUILD" ]]; then
  die "usage: $0 <jenkins-build-number>"
fi
if ! [[ "$BUILD" =~ ^[0-9]+$ ]]; then
  die "build number must be digits (got: ${BUILD})"
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
source "${SCRIPT_DIR}/lib/harbor-manifest-check.sh"

[[ -n "${GITHUB_TOKEN:-}" ]] || die "set GITHUB_TOKEN"
command -v curl >/dev/null || die "curl required"
command -v kubectl >/dev/null || die "kubectl required"

kubectl get pods -n harbor -l app=harbor,component=registry -o wide | grep -q Running || \
  die "harbor-registry not running"
V2_CODE="$(curl -sS -o /dev/null -w '%{http_code}' -I "http://${NODE_IP}:${HARBOR_PORT}/v2/")"
[[ "$V2_CODE" == "401" || "$V2_CODE" == "200" ]] || die "Harbor /v2/ HTTP ${V2_CODE}"

if [[ "${PURGE_HARBOR_REPO:-}" == "1" ]]; then
  curl -sS -o /dev/null -w "DELETE repo HTTP %{http_code}\n" -X DELETE \
    -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "http://${NODE_IP}:${HARBOR_PORT}/api/v2.0/projects/paas/repositories/simple-app" || true
  sleep 3
fi

HARBOR_HOST="${NODE_IP}:${HARBOR_PORT}"
MAN_CODE="$(harbor_manifest_http_code "${HARBOR_HOST}" "paas/simple-app" "${BUILD}" "${HARBOR_USER}" "${HARBOR_PASS}")"
echo "manifest tag ${BUILD} -> HTTP ${MAN_CODE}"
if [[ "$MAN_CODE" != "200" && "$MAN_CODE" != "301" ]]; then
  if ! harbor_image_pullable "${IMAGE_REPO}:${BUILD}" "${HARBOR_USER}" "${HARBOR_PASS}"; then
    die "image ${IMAGE_REPO}:${BUILD} not in Harbor; run Jenkins paas-deploy first"
  fi
fi

[[ -d "${GITOPS_DIR}/.git" ]] || git clone https://github.com/nourhb/gitops.git "${GITOPS_DIR}"
VALUES="${GITOPS_DIR}/apps/simple-app/values.yaml"
[[ -f "$VALUES" ]] || die "missing ${VALUES}"
sed -i "s/^  tag:.*/  tag: \"${BUILD}\"/" "$VALUES"
grep -q "runAsNonRoot: false" "${GITOPS_DIR}/apps/simple-app/templates/deployment.yaml" 2>/dev/null || \
  sed -i 's/runAsNonRoot: true/runAsNonRoot: false/g' "${GITOPS_DIR}/apps/simple-app/templates/deployment.yaml" 2>/dev/null || true

cd "${GITOPS_DIR}"
git add apps/simple-app/values.yaml apps/simple-app/templates/deployment.yaml 2>/dev/null || git add apps/simple-app/values.yaml
git diff --cached --quiet && echo "gitops tag already ${BUILD}" || git commit -m "chore(simple-app): tag ${BUILD}"
GIT_REMOTE="https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git"
git pull --rebase "${GIT_REMOTE}" main
git push "${GIT_REMOTE}" main

command -v argocd >/dev/null && argocd app sync paas-simple-app --force || true

bash "${SCRIPT_DIR}/fix-simple-app-lab.sh" pull "${BUILD}"

kubectl get pods -n "$NS" -o wide
HTTP_CODE="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" 2>/dev/null || true)"
HTTP_CODE="${HTTP_CODE:-000}"
echo "${APP_URL} -> HTTP ${HTTP_CODE}"
kubectl get pods -n "$NS" | grep -q "1/1.*Running" && [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "304" ]] && \
  echo "ok" || die "pod or HTTP check failed"
