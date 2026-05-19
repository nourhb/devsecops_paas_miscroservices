#!/usr/bin/env bash
# Fix PaaS frontend ImagePullBackOff (Harbor HTTP + pull secret + optional local import).
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
PAAS_NS="${PAAS_NS:-paas}"
IMAGE="${HARBOR}/paas/paas-frontend:latest"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

man_code() {
  curl -sS -o /dev/null -w '%{http_code}' -I -u "${HARBOR_USER}:${HARBOR_PASS}" \
    "http://${HARBOR}/v2/paas/paas-frontend/manifests/latest" 2>/dev/null || echo "000"
}

echo "=== [1] Harbor manifest paas-frontend:latest ==="
MAN="$(man_code)"
echo "MAN → HTTP ${MAN}"

if [[ "$MAN" != "200" ]]; then
  echo "=== [2] Build + push (from ${REPO_ROOT}) ==="
  cd "${REPO_ROOT}"
  docker build -f docker/frontend.Dockerfile -t "${IMAGE}" .
  echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
  docker push "${IMAGE}"
  MAN="$(man_code)"
  echo "MAN after push → HTTP ${MAN}"
fi
[[ "$MAN" == "200" ]] || { echo "ERROR: paas-frontend:latest not in Harbor registry storage"; exit 1; }

echo "=== [3] Pull secret + deployment patch ==="
kubectl create secret docker-registry harbor-regcred \
  --docker-server="${HARBOR}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASS}" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl set image deployment/frontend -n "${PAAS_NS}" frontend="${IMAGE}"
kubectl patch deployment frontend -n "${PAAS_NS}" -p '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"harbor-regcred"}]}}}}'

echo "=== [4] k3s: allow HTTP Harbor (run on EACH node if pull still fails) ==="
cat <<'REGDOC'
sudo tee /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  "192.168.56.129:30002":
    endpoint:
      - "http://192.168.56.129:30002"
configs:
  "192.168.56.129:30002":
    auth:
      username: admin
      password: Harbor12345
    tls:
      insecure_skip_verify: true
EOF
sudo systemctl restart k3s || sudo systemctl restart k3s-agent
REGDOC

echo "=== [5] Import image into k3s on master (works if nodes cannot pull HTTP yet) ==="
if command -v docker >/dev/null && docker image inspect "${IMAGE}" >/dev/null 2>&1; then
  docker pull "${IMAGE}" 2>/dev/null || true
  TMP=/tmp/paas-frontend-latest.tar
  docker save "${IMAGE}" -o "${TMP}"
  if command -v k3s >/dev/null; then
    sudo k3s ctr images import "${TMP}" 2>/dev/null || true
  fi
  rm -f "${TMP}"
fi

echo "=== [6] Rollout (schedule on master where image may already exist) ==="
kubectl patch deployment frontend -n "${PAAS_NS}" -p '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"master"}}}}}}' || true
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0
sleep 5
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 2>/dev/null || true
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s || true

echo "=== [7] Status ==="
kubectl get pods,svc -n "${PAAS_NS}" -l app=frontend -o wide
kubectl describe pod -n "${PAAS_NS}" -l app=frontend 2>/dev/null | tail -12 || true
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${NODE_IP}:30100/" 2>/dev/null || echo "000")"
echo "PaaS http://${NODE_IP}:30100/ → HTTP ${HTTP}"
