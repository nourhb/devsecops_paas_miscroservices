#!/usr/bin/env bash
# Fix simple-app ImagePullBackOff: secret, import on master, or local build if Harbor blobs are corrupt.
#
# Harbor "short read: unexpected EOF" = metadata OK but layer blobs truncated (re-push or LOCAL_BUILD=1).
#
# Usage:
#   bash paas/scripts/fix-simple-app-imagepull-lab.sh 104
#   LOCAL_BUILD=1 bash paas/scripts/fix-simple-app-imagepull-lab.sh 104
set -euo pipefail

TAG="${TAG:-${1:-}}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
IMAGE="${HARBOR}/paas/simple-app:${TAG}"
NS="${NS:-simple-app}"
DEPLOY="${DEPLOY:-paas-simple-app-simple-app}"
GIT_REPO="${GIT_REPO:-https://github.com/nourhb/simple-app.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -n "$TAG" && "$TAG" =~ ^[0-9]+$ ]] || die "Usage: $0 104"

echo "=== [1] Pull secret in ${NS} ==="
if kubectl get secret harbor-regcred -n "${NS}" >/dev/null 2>&1; then
  echo "harbor-regcred already exists in ${NS} (skip copy to avoid Conflict)"
else
  kubectl create secret docker-registry harbor-regcred \
    --docker-server="${HARBOR}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    -n "${NS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

obtain_image_on_docker() {
  if [[ "${LOCAL_BUILD:-}" == "1" ]]; then
    return 1
  fi
  echo "=== [2] docker pull ${IMAGE} (Harbor blobs must be intact) ==="
  echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
  local i
  for i in 1 2 3; do
    if docker pull "${IMAGE}"; then
      return 0
    fi
    echo "WARN: pull attempt ${i} failed (short read / EOF = corrupt Harbor layer)"
    sleep 10
  done
  return 1
}

build_image_locally() {
  echo "=== [2b] Build image locally (bypass corrupt Harbor blobs) ==="
  local dir
  dir="$(mktemp -d /tmp/simple-app-build-XXXXXX)"
  trap 'rm -rf "${dir}"' RETURN
  git clone --depth 1 --branch "${GIT_BRANCH}" "${GIT_REPO}" "${dir}"
  cd "${dir}"
  [[ -f Dockerfile ]] || die "No Dockerfile in ${GIT_REPO}"
  # Repo has no public/ but Dockerfile COPY expects it (Next.js allows empty public)
  mkdir -p public
  docker build -t "${IMAGE}" .
  echo "Built ${IMAGE} on master"
  if [[ "${PUSH_TO_HARBOR:-}" == "1" ]]; then
    echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
    docker push "${IMAGE}" || echo "WARN: push to Harbor failed — k3s import still works on master"
  fi
}

if obtain_image_on_docker; then
  echo "Using image from Harbor pull"
elif [[ "${LOCAL_BUILD:-}" == "1" ]] || [[ "${AUTO_LOCAL_BUILD:-}" != "0" ]]; then
  build_image_locally
else
  die "docker pull failed for ${IMAGE}.
Harbor serves MAN 200 but blobs are corrupt (short read / EOF).

Fix options:
  1) LOCAL_BUILD=1 bash $0 ${TAG}
  2) Trigger new Jenkins paas-deploy build, then: bash $0 <new_build>
  3) Repair Harbor storage, delete tag ${TAG}, re-push from Jenkins"
fi

echo "=== [3] Import into k3s on master ==="
TMP="/tmp/simple-app-${TAG}-$$.tar"
docker save "${IMAGE}" -o "${TMP}"
sudo k3s ctr images import "${TMP}"
rm -f "${TMP}"

echo "=== [4] Patch deployment (master + IfNotPresent) ==="
kubectl set image "deployment/${DEPLOY}" -n "${NS}" "simple-app=${IMAGE}" 2>/dev/null || \
  kubectl set image "deployment/${DEPLOY}" -n "${NS}" "*=${IMAGE}"
kubectl patch "deployment/${DEPLOY}" -n "${NS}" --type=strategic -p "{
  \"spec\": {
    \"template\": {
      \"spec\": {
        \"imagePullSecrets\": [{\"name\": \"harbor-regcred\"}],
        \"nodeSelector\": {\"kubernetes.io/hostname\": \"master\"},
        \"containers\": [{
          \"name\": \"simple-app\",
          \"imagePullPolicy\": \"IfNotPresent\"
        }]
      }
    }
  }
}" 2>/dev/null || kubectl patch "deployment/${DEPLOY}" -n "${NS}" -p \
  "{\"spec\":{\"template\":{\"spec\":{\"imagePullSecrets\":[{\"name\":\"harbor-regcred\"}],\"nodeSelector\":{\"kubernetes.io/hostname\":\"master\"}}}}}"

echo "=== [5] Rollout ==="
kubectl scale "deployment/${DEPLOY}" -n "${NS}" --replicas=0
sleep 3
kubectl delete pods -n "${NS}" -l app.kubernetes.io/name=simple-app --force --grace-period=0 2>/dev/null || true
kubectl delete rs -n "${NS}" -l app.kubernetes.io/name=simple-app 2>/dev/null || true
kubectl scale "deployment/${DEPLOY}" -n "${NS}" --replicas=1
kubectl rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout=600s || true

echo "=== [6] Status ==="
kubectl get pods -n "${NS}" -o wide
kubectl describe pod -n "${NS}" -l app.kubernetes.io/name=simple-app 2>/dev/null | tail -12 || true
APP_URL="http://simple-app.${NODE_IP}.nip.io:30659/"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" 2>/dev/null || true)"
HTTP="${HTTP:-000}"
echo "App ${APP_URL} → HTTP ${HTTP}"
