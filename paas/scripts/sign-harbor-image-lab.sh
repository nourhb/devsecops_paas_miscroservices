#!/usr/bin/env bash
# Cosign-sign a Harbor image tag and its digest (fixes Kyverno require-signed-images after crane-only tag sign).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
IMAGE="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "${IMAGE}" ]] || die "Usage: $0 <registry/project/repo:tag>"
[[ -f "${KEYDIR}/cosign.key" ]] || die "Missing ${KEYDIR}/cosign.key — run: bash paas/scripts/setup-security-lab.sh"
command -v cosign >/dev/null 2>&1 || die "Install cosign on the VM"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck disable=SC1090
  set +u; source "${ENV_FILE}" 2>/dev/null || true; set -u
fi

export COSIGN_PASSWORD=""
COSIGN_FLAGS=(--yes --allow-insecure-registry --key "${KEYDIR}/cosign.key")
VERIFY_FLAGS=(--allow-insecure-registry --key "${KEYDIR}/cosign.pub")

resolve_digest_ref() {
  local img="$1"
  local raw="" tri="" repo="" hex=""

  if command -v crane >/dev/null 2>&1; then
    raw="$(crane digest "${img}" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "${raw}" == *@sha256:* ]]; then
      printf '%s\n' "${raw}"
      return 0
    fi
    if [[ "${raw}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
      printf '%s@%s\n' "${img%:*}" "${raw}"
      return 0
    fi
  fi

  tri="$(cosign triangulate "${img}" --allow-insecure-registry 2>/dev/null || true)"
  if [[ "${tri}" =~ :sha256-[a-f0-9]{64} ]]; then
    repo="${tri%%:sha256-*}"
    hex="${tri#*:sha256-}"
    hex="${hex%.sig}"
    printf '%s@sha256:%s\n' "${repo}" "${hex}"
    return 0
  fi

  if [[ -n "${HARBOR_BASE_URL:-}" && -n "${HARBOR_USERNAME:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
    local registry="${HARBOR_REGISTRY:-}"
    local tag_match repo_path harbor_project repository digest
    if [[ "${img}" == "${registry}/"* && "${img}" == *:* ]]; then
      repo_path="${img#${registry}/}"
      repo_path="${repo_path%:*}"
      tag_match="${img##*:}"
      harbor_project="${repo_path%%/*}"
      repository="${repo_path#*/}"
      digest="$(curl -fsS -u "${HARBOR_USERNAME}:${HARBOR_PASSWORD}" \
        "${HARBOR_BASE_URL%/}/api/v2.0/projects/${harbor_project}/repositories/${repository}/artifacts/${tag_match}" \
        | python3 -c "import json,sys; d=json.load(sys.stdin).get('digest','').strip(); print(d)" 2>/dev/null || true)"
      if [[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
        printf '%s@%s\n' "${img%:*}" "${digest}"
        return 0
      fi
    fi
  fi
  return 1
}

digest_ref=""
if digest_ref="$(resolve_digest_ref "${IMAGE}")"; then
  echo "==> Resolved digest ${digest_ref}"
else
  echo "WARN: could not resolve digest — will sign tag first, then retry digest"
fi

echo "==> Sign digest (required for Kyverno verifyImages)"
if [[ -n "${digest_ref}" ]]; then
  cosign sign "${COSIGN_FLAGS[@]}" "${digest_ref}"
  cosign verify "${VERIFY_FLAGS[@]}" "${digest_ref}"
else
  echo "==> Sign tag (bootstrap digest resolution)"
  cosign sign "${COSIGN_FLAGS[@]}" "${IMAGE}"
  if digest_ref="$(resolve_digest_ref "${IMAGE}")"; then
    echo "==> Resolved digest after tag sign: ${digest_ref}"
    cosign sign "${COSIGN_FLAGS[@]}" "${digest_ref}"
    cosign verify "${VERIFY_FLAGS[@]}" "${digest_ref}"
  else
    echo "WARN: digest still unknown — Kyverno may block until digest is signed"
  fi
fi

echo "==> Sign tag"
cosign sign "${COSIGN_FLAGS[@]}" "${IMAGE}"
cosign verify "${VERIFY_FLAGS[@]}" "${IMAGE}"

echo "OK: ${IMAGE}"
if [[ -n "${digest_ref}" ]]; then
  echo "OK: digest ${digest_ref}"
fi
