#!/usr/bin/env bash
# Diagnose Harbor: push succeeds but /v2/.../manifests/<tag> → 404.
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
REPO="${1:-paas/paas-frontend}"
TAG="${2:-latest}"

auth=(-u "${HARBOR_USER}:${HARBOR_PASS}")

echo "=== Pods (registry must be 2/2 Running) ==="
kubectl get pods -n harbor -l app=harbor,component=registry -o wide
kubectl get pvc -n harbor 2>/dev/null | head -20 || true

echo ""
echo "=== /v2/ ping ==="
curl -sS -o /dev/null -w "GET /v2/ → HTTP %{http_code}\n" -I "http://${HARBOR}/v2/"

echo ""
echo "=== Manifest HEAD (several Accept types) ==="
for accept in \
  "application/vnd.docker.distribution.manifest.v2+json" \
  "application/vnd.oci.image.manifest.v1+json"; do
  code="$(curl -sS -o /dev/null -w '%{http_code}' -I "${auth[@]}" \
    -H "Accept: ${accept}" \
    "http://${HARBOR}/v2/${REPO}/manifests/${TAG}" 2>/dev/null || echo "000")"
  echo "  Accept ${accept} → HTTP ${code}"
done

echo ""
echo "=== Tags list ==="
curl -sS "${auth[@]}" "http://${HARBOR}/v2/${REPO}/tags/list" 2>/dev/null || echo "(tags/list failed)"

echo ""
echo "=== Harbor API artifacts ==="
base="$(basename "$REPO")"
curl -sS "${auth[@]}" \
  "http://${HARBOR}/api/v2.0/projects/paas/repositories/${base}/artifacts?page_size=5" 2>/dev/null \
  | head -c 2000 || echo "(API failed)"
echo ""

echo ""
echo "=== docker pull test (from this host) ==="
if command -v docker >/dev/null; then
  echo "${HARBOR_PASS}" | docker login "${HARBOR}" -u "${HARBOR_USER}" --password-stdin 2>/dev/null || true
  if docker pull "${HARBOR}/${REPO}:${TAG}" 2>&1; then
    echo "docker pull → OK (image is pullable even if curl MAN was 404)"
  else
    echo "docker pull → FAILED (registry not serving blobs)"
  fi
else
  echo "docker not installed — skip pull test"
fi

echo ""
echo "=== Recent registry container logs ==="
kubectl logs -n harbor -l app=harbor,component=registry -c registry --tail=30 2>/dev/null || true

echo ""
echo "=== Suggested recovery (if pull fails) ==="
cat <<'EOF'
1. Restart Harbor data plane:
   kubectl rollout restart deployment -n harbor harbor-registry harbor-nginx harbor-core
   kubectl wait --for=condition=ready pod -l app=harbor,component=registry -n harbor --timeout=300s

2. Do NOT delete repos before a fresh push unless you will re-push immediately.

3. Re-push from monorepo:
   cd ~/devsecops_paas_miscroservices/paas
   docker build -f docker/frontend.Dockerfile -t 192.168.56.129:30002/paas/paas-frontend:latest .
   docker push 192.168.56.129:30002/paas/paas-frontend:latest

4. PaaS UI without Harbor: bash paas/scripts/fix-paas-frontend-pull-lab.sh
EOF
