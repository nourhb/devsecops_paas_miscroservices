#!/usr/bin/env bash
# Cosign-sign a Harbor image tag and its digest (fixes Kyverno require-signed-images after crane-only tag sign).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
IMAGE="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${IMAGE}" ]] || die "Usage: $0 <registry/project/repo:tag>"
[[ -f "${KEYDIR}/cosign.key" ]] || die "Missing ${KEYDIR}/cosign.key — run: bash paas/scripts/setup-security-lab.sh"
command -v cosign >/dev/null 2>&1 || die "Install cosign on the VM"

export COSIGN_PASSWORD=""

digest_ref=""
if command -v crane >/dev/null 2>&1; then
  raw="$(crane digest "${IMAGE}" 2>/dev/null | tr -d '\r\n' || true)"
  if [[ "${raw}" == *@sha256:* ]]; then
    digest_ref="${raw}"
  elif [[ "${raw}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    digest_ref="${IMAGE%:*}@${raw}"
  fi
fi

echo "==> Sign digest (required for Kyverno verifyImages)"
if [[ -n "${digest_ref}" ]]; then
  cosign sign --yes --allow-insecure-registry --key "${KEYDIR}/cosign.key" "${digest_ref}"
  cosign verify --key "${KEYDIR}/cosign.pub" --allow-insecure-registry "${digest_ref}"
else
  echo "WARN: could not resolve digest — install crane or pass digest@sha256:… manually"
fi

echo "==> Sign tag"
cosign sign --yes --allow-insecure-registry --key "${KEYDIR}/cosign.key" "${IMAGE}"
cosign verify --key "${KEYDIR}/cosign.pub" --allow-insecure-registry "${IMAGE}"

echo "OK: ${IMAGE}"
