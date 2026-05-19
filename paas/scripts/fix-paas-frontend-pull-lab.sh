#!/usr/bin/env bash
# Fix PaaS frontend: build, optional Harbor push, k3s import on master, rollout.
#
# Harbor may report "docker push OK" but /v2/.../manifests/latest → 404 (ghost DB / registry PVC).
# This script still brings the UI up by importing the image into k3s on the master node.
#
# Usage (from repo root):
#   bash paas/scripts/fix-paas-frontend-pull-lab.sh
#   SKIP_HARBOR_PUSH=1 bash paas/scripts/fix-paas-frontend-pull-lab.sh   # import only
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
PAAS_NS="${PAAS_NS:-paas}"
IMAGE="${HARBOR}/paas/paas-frontend:latest"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONOREPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PAAS_DIR="${MONOREPO_ROOT}/paas"

man_code() {
  local accept="$1"
  curl -sS -o /dev/null -w '%{http_code}' -I -u "${HARBOR_USER}:${HARBOR_PASS}" \
    -H "Accept: ${accept}" \
    "http://${HARBOR}/v2/paas/paas-frontend/manifests/latest" 2>/dev/null || echo "000"
}

harbor_manifest_ok() {
  local c
  for accept in \
    "application/vnd.docker.distribution.manifest.v2+json" \
    "application/vnd.oci.image.manifest.v1+json" \
    "application/vnd.docker.distribution.manifest.list.v2+json"; do
    c="$(man_code "${accept}")"
    [[ "$c" == "200" || "$c" == "301" ]] && return 0
  done
  return 1
}

echo "=== [1] Harbor manifest paas-frontend:latest ==="
if harbor_manifest_ok; then
  echo "MAN → OK (registry serves tag latest)"
else
  echo "MAN → not 200 (Harbor may have ghost metadata or registry storage issue)"
fi

echo "=== [2] Build image (context: ${PAAS_DIR}) ==="
[[ -f "${PAAS_DIR}/docker/frontend.Dockerfile" ]] || {
  echo "ERROR: missing ${PAAS_DIR}/docker/frontend.Dockerfile"
  exit 1
}
cd "${PAAS_DIR}"
docker build -f docker/frontend.Dockerfile -t "${IMAGE}" .

if [[ "${SKIP_HARBOR_PUSH:-}" != "1" ]]; then
  echo "=== [3] Push to Harbor (optional; may not fix MAN 404) ==="
  echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin
  docker push "${IMAGE}" || echo "WARN: docker push failed — continuing with local import"
  if harbor_manifest_ok; then
    echo "MAN after push → OK"
  else
    echo "MAN after push → still not 200 (use k3s import below; fix Harbor separately)"
    echo "  bash paas/scripts/diagnose-harbor-registry-lab.sh"
  fi
else
  echo "=== [3] Skip Harbor push (SKIP_HARBOR_PUSH=1) ==="
fi

echo "=== [4] Import image into k3s on this node (master) ==="
TMP="/tmp/paas-frontend-latest-$$.tar"
docker save "${IMAGE}" -o "${TMP}"
if command -v k3s >/dev/null; then
  sudo k3s ctr images import "${TMP}"
else
  echo "WARN: k3s not found — run this script on the k3s master"
fi
rm -f "${TMP}"

echo "=== [5] Pull secret + deployment (pull from Harbor if possible, else use imported image) ==="
kubectl create secret docker-registry harbor-regcred \
  --docker-server="${HARBOR}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASS}" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl set image deployment/frontend -n "${PAAS_NS}" frontend="${IMAGE}"
kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "imagePullSecrets": [{"name": "harbor-regcred"}],
        "nodeSelector": {"kubernetes.io/hostname": "master"},
        "containers": [{
          "name": "frontend",
          "imagePullPolicy": "IfNotPresent"
        }]
      }
    }
  }
}' 2>/dev/null || kubectl patch deployment frontend -n "${PAAS_NS}" -p \
  '{"spec":{"template":{"spec":{"imagePullSecrets":[{"name":"harbor-regcred"}],"nodeSelector":{"kubernetes.io/hostname":"master"}}}}}'

echo "=== [6] k3s HTTP registry on worker nodes (if pod schedules off master later) ==="
cat <<REGDOC
On worker1 and worker2 (not only master), run:
sudo tee /etc/rancher/k3s/registries.yaml <<'EOF'
mirrors:
  "${HARBOR}":
    endpoint:
      - "http://${HARBOR}"
configs:
  "${HARBOR}":
    auth:
      username: ${HARBOR_USER}
      password: ${HARBOR_PASS}
    tls:
      insecure_skip_verify: true
EOF
sudo systemctl restart k3s-agent
REGDOC

echo "=== [7] NodePort Service (30100 → pod :3000) ==="
kubectl apply -f "${MONOREPO_ROOT}/paas/k8s-manifests/lab/frontend-nodeport-service.yaml"
# Legacy labs used other service names; keep selector app=frontend
if kubectl get svc frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  kubectl patch svc frontend -n "${PAAS_NS}" --type=merge -p \
    '{"spec":{"type":"NodePort","selector":{"app":"frontend"},"ports":[{"name":"http","port":80,"targetPort":3000,"nodePort":30100,"protocol":"TCP"}]}}' \
    2>/dev/null || true
fi

echo "=== [8] Rollout ==="
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0
sleep 5
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 2>/dev/null || true
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s || true

echo "=== [9] Status ==="
kubectl get pods,svc,endpoints -n "${PAAS_NS}" -l app=frontend -o wide 2>/dev/null || kubectl get pods,svc,endpoints -n "${PAAS_NS}" | grep -E 'frontend|NAME' || true
kubectl wait --for=condition=ready pod -n "${PAAS_NS}" -l app=frontend --timeout=120s 2>/dev/null || true
EP="$(kubectl get endpoints frontend-service -n "${PAAS_NS}" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
if [[ -z "${EP}" ]]; then
  echo "WARN: frontend-service has no endpoints — check: kubectl get svc,endpoints -n ${PAAS_NS}"
fi

sleep 2
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 "http://${NODE_IP}:30100/" 2>/dev/null || true)"
HTTP="${HTTP:-000}"
echo "PaaS http://${NODE_IP}:30100/ → HTTP ${HTTP}"
if [[ "$HTTP" != "200" && "$HTTP" != "302" && "$HTTP" != "307" ]]; then
  echo "Try: curl -sS http://127.0.0.1:30100/api/health"
  echo "Logs: kubectl logs -n ${PAAS_NS} -l app=frontend --tail=40"
  exit 1
fi
