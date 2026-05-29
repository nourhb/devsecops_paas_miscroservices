#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAAS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPO_ROOT="$(cd "${PAAS_DIR}/.." && pwd)"
DOCKERFILE="${PAAS_DIR}/frontend/Dockerfile"

die() { echo "ERROR: $*" >&2; exit 1; }

ensure_dockerfile() {
  if [[ -f "${DOCKERFILE}" ]] && [[ "$(wc -c < "${DOCKERFILE}")" -gt 100 ]]; then
    return 0
  fi
  echo "WARN: ${DOCKERFILE} missing or empty — restoring from git"
  git -C "${REPO_ROOT}" checkout -- paas/frontend/Dockerfile paas/frontend/Dockerfile.db 2>/dev/null || true
  if [[ -f "${DOCKERFILE}" ]] && [[ "$(wc -c < "${DOCKERFILE}")" -gt 100 ]]; then
    return 0
  fi
  die "Missing paas/frontend/Dockerfile. From repo root run:
  git checkout paas/frontend/Dockerfile
  ls -la paas/frontend/Dockerfile"
}

ensure_dockerfile
cd "${PAAS_DIR}"

HARBOR="${HARBOR_REGISTRY:-192.168.56.129:30002}"
IMAGE="${HARBOR}/paas/paas-frontend:latest"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
PAAS_NS="${PAAS_NS:-paas}"

echo "==> Building ${IMAGE} (context: ${PAAS_DIR})"
BUILD_ARGS=()
if [[ "${BUILD_NO_CACHE:-}" == "1" || "${BUILD_NO_CACHE:-}" == "true" ]]; then
  echo "    BUILD_NO_CACHE=${BUILD_NO_CACHE} — forcing fresh npm run build"
  BUILD_ARGS+=(--no-cache)
fi
docker build "${BUILD_ARGS[@]}" -f frontend/Dockerfile -t "$IMAGE" .

echo "==> Pushing to Harbor"
if echo "$HARBOR_PASS" | docker login "$HARBOR" -u "$HARBOR_USER" --password-stdin 2>/dev/null; then
  docker push "$IMAGE" || echo "WARN: push failed — will still import locally to k3s"
else
  echo "WARN: Harbor login failed (502/registry down?) — skipping push; importing image locally to k3s"
fi

echo "==> Import into k3s on master (avoids ImagePullBackOff when Harbor MAN is 404)"
TMP="/tmp/paas-frontend-deploy-$$.tar"
docker save "$IMAGE" -o "$TMP"
sudo k3s ctr images import "$TMP"
rm -f "$TMP"

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
kubectl set image deployment/frontend -n "${PAAS_NS}" frontend="${IMAGE}"
kubectl patch deployment frontend -n "${PAAS_NS}" -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"master"},"containers":[{"name":"frontend","imagePullPolicy":"IfNotPresent"}]}}}}' \
  2>/dev/null || true

echo "==> Restarting deployment/frontend in namespace ${PAAS_NS}"
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0
sleep 3
kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 2>/dev/null || true
kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=1
kubectl rollout status deployment/frontend -n "${PAAS_NS}" --timeout=600s

ENV_FILE="${ENV_FILE:-${PAAS_DIR}/frontend/docker-compose.env}"
if [[ -f "${ENV_FILE}" ]]; then
  echo "==> Sync runtime env (SMTP, APP_BASE_URL, integrations) to deployment/frontend"
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
else
  echo "WARN: ${ENV_FILE} missing — run sync-paas-frontend-env-k8s.sh after creating it (SMTP lives there for k8s)."
fi

if grep -qF 'crane-next16-202605' "${PAAS_DIR}/jenkins/Jenkinsfile.paas-deploy" 2>/dev/null; then
  echo "==> Mount current Jenkinsfile into frontend pod (overrides stale image COPY)"
  bash "${SCRIPT_DIR}/sync-paas-jenkinsfile-configmap-k8s.sh" || true
fi

curl -sf "http://127.0.0.1:30100/api/health" | head -c 200 || true
echo ""
echo "OK: http://192.168.56.129:30100"
