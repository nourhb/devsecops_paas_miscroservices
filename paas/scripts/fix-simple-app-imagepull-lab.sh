#!/usr/bin/env bash
# Fix simple-app ImagePullBackOff: pull secret, k3s import on master, rollout.
#
# Usage:
#   TAG=104 bash paas/scripts/fix-simple-app-imagepull-lab.sh
#   bash paas/scripts/fix-simple-app-imagepull-lab.sh 104
set -euo pipefail

TAG="${TAG:-${1:-}}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
IMAGE="${HARBOR}/paas/simple-app:${TAG}"
NS="${NS:-simple-app}"
DEPLOY="${DEPLOY:-paas-simple-app-simple-app}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ -n "$TAG" && "$TAG" =~ ^[0-9]+$ ]] || die "Usage: TAG=104 $0   or   $0 104"

echo "=== [1] Pull secret in ${NS} ==="
if kubectl get secret harbor-regcred -n paas >/dev/null 2>&1; then
  kubectl get secret harbor-regcred -n paas -o yaml \
    | sed "s/namespace: paas/namespace: ${NS}/" \
    | kubectl apply -f -
elif kubectl get secret harbor-regcred -n harbor >/dev/null 2>&1; then
  kubectl get secret harbor-regcred -n harbor -o yaml \
    | sed "s/namespace: harbor/namespace: ${NS}/" \
    | kubectl apply -f -
else
  kubectl create secret docker-registry harbor-regcred \
    --docker-server="${HARBOR}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    -n "${NS}" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

echo "=== [2] Pull image on master (retry; Harbor layers can EOF) ==="
echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
for i in 1 2 3; do
  if docker pull "${IMAGE}"; then
    break
  fi
  echo "WARN: docker pull attempt ${i} failed — retrying in 10s"
  sleep 10
  [[ "$i" -eq 3 ]] && die "docker pull failed for ${IMAGE}"
done

echo "=== [3] Import into k3s on master ==="
TMP="/tmp/simple-app-${TAG}-$$.tar"
docker save "${IMAGE}" -o "${TMP}"
sudo k3s ctr images import "${TMP}"
rm -f "${TMP}"

echo "=== [4] Patch deployment (master + IfNotPresent + pull secret) ==="
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
kubectl scale "deployment/${DEPLOY}" -n "${NS}" --replicas=1
kubectl rollout status "deployment/${DEPLOY}" -n "${NS}" --timeout=600s || true

echo "=== [6] Status ==="
kubectl get pods -n "${NS}" -o wide
kubectl describe pod -n "${NS}" -l app.kubernetes.io/name=simple-app 2>/dev/null | tail -15 || true
APP_URL="http://simple-app.${NODE_IP}.nip.io:30659/"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 "${APP_URL}" 2>/dev/null || true)"
HTTP="${HTTP:-000}"
echo "App ${APP_URL} → HTTP ${HTTP}"
echo ""
echo "Workers still need HTTP Harbor in /etc/rancher/k3s/registries.yaml if you remove nodeSelector later."
