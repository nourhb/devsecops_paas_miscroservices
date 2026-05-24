#!/usr/bin/env bash
set -euo pipefail

NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR="${HARBOR:-${NODE_IP}:30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
REPO="${1:-paas/paas-frontend}"
TAG="${2:-latest}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/lib/harbor-manifest-check.sh"

auth=(-u "${HARBOR_USER}:${HARBOR_PASS}")

echo "=== Pods (registry must be 2/2 Running) ==="
kubectl get pods -n harbor -l app=harbor,component=registry -o wide
kubectl get pvc -n harbor 2>/dev/null | head -20 || true

echo ""
echo "=== /v2/ ping ==="
curl -sS -o /dev/null -w "GET /v2/ → HTTP %{http_code}\n" -I "http://${HARBOR}/v2/"

echo ""
echo "=== Manifest HEAD (naive vs OCI-aware) ==="
NAIVE="$(curl -sS -o /dev/null -w '%{http_code}' -I "${auth[@]}" \
  "http://${HARBOR}/v2/${REPO}/manifests/${TAG}" 2>/dev/null || echo "000")"
echo "  curl -I (no Accept) → HTTP ${NAIVE}  (404 often means OCI index, not missing image)"
OCI_CODE="$(harbor_manifest_http_code "${HARBOR}" "${REPO}" "${TAG}" "${HARBOR_USER}" "${HARBOR_PASS}")"
echo "  OCI-aware check   → HTTP ${OCI_CODE}"

echo ""
echo "=== Tags list ==="
curl -sS "${auth[@]}" "http://${HARBOR}/v2/${REPO}/tags/list" 2>/dev/null || echo "(tags/list failed)"

echo ""
echo "=== Harbor API artifacts ==="
base="$(basename "$REPO")"
curl -sS "${auth[@]}" \
  "http://${HARBOR}/api/v2.0/projects/paas/repositories/${base}/artifacts?page_size=3" 2>/dev/null \
  | head -c 1500 || echo "(API failed)"
echo ""

echo ""
echo "=== docker pull test ==="
if command -v docker >/dev/null; then
  if harbor_image_pullable "${HARBOR}/${REPO}:${TAG}" "${HARBOR_USER}" "${HARBOR_PASS}"; then
    echo "docker pull ${HARBOR}/${REPO}:${TAG} → OK"
  else
    echo "docker pull → FAILED"
  fi
else
  echo "docker not installed — skip"
fi

echo ""
echo "=== Registry log hint ==="
echo 'If you see: "OCI index found, but accept header does not support OCI indexes" → image is fine; use harbor_manifest_http_code or docker pull.'
