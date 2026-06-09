#!/usr/bin/env bash
# Install or repair Dependency-Track on k3s lab (NodePort + API_BASE_URL for browser login).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
NS="dependency-track"
RELEASE="dtrack"
FE_NP="${DT_FRONTEND_NODEPORT:-31992}"
API_NP="${DT_API_NODEPORT:-30353}"
API_BASE="http://${NODE_IP}:${API_NP}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: need $1" >&2; exit 1; }; }
need kubectl
need helm
need curl

echo "==> Helm repo"
helm repo add dependency-track https://dependencytrack.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update dependency-track >/dev/null

echo "==> Install ${RELEASE} in ${NS} (UI :${FE_NP}, API :${API_NP})"
helm upgrade --install "${RELEASE}" dependency-track/dependency-track -n "${NS}" --create-namespace \
  --set frontend.service.type=NodePort \
  --set "frontend.service.nodePort=${FE_NP}" \
  --set apiServer.service.type=NodePort \
  --set "apiServer.service.nodePort=${API_NP}" \
  --set "frontend.apiBaseUrl=${API_BASE}" \
  --set apiServer.resources.requests.cpu=100m \
  --set apiServer.resources.requests.memory=512Mi \
  --set apiServer.resources.limits.memory=1536Mi

echo "==> Wait for pods"
kubectl wait --for=condition=ready pod -l app.kubernetes.io/instance="${RELEASE}" -n "${NS}" --timeout=600s 2>/dev/null || true
kubectl get pods -n "${NS}" -o wide

echo "==> API probe"
for i in $(seq 1 60); do
  if curl -fsS -m 5 "${API_BASE}/api/version" >/dev/null 2>&1; then
    echo "OK: ${API_BASE}/api/version"
    break
  fi
  echo "  waiting API (${i}/60)…"
  sleep 10
done
curl -fsS "${API_BASE}/api/version" || { echo "WARN: API not ready yet — kubectl get pods -n ${NS}" >&2; }

echo ""
echo "Dependency-Track UI:  http://${NODE_IP}:${FE_NP}"
echo "Dependency-Track API: ${API_BASE}"
echo ""
echo "Change default password (admin/admin → admin123):"
echo "  curl -X POST '${API_BASE}/api/v1/user/forceChangePassword' \\"
echo "    -d username=admin -d password=admin -d newPassword=admin123 -d confirmPassword=admin123"
echo ""
echo "Wire env + sync PaaS:"
echo "  ENV_FILE=${ENV_FILE} bash paas/scripts/wire-optional-integrations-lab.sh"
echo "  bash paas/scripts/regenerate-dependency-track-api-key-lab.sh"
