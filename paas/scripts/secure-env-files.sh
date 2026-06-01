#!/usr/bin/env bash
# Verify env files are gitignored, not tracked, and (on Unix) owner-readable only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FIX="${1:-}"

ENV_CANDIDATES=(
  "${REPO_ROOT}/paas/.env"
  "${REPO_ROOT}/paas/frontend/.env"
  "${REPO_ROOT}/paas/frontend/docker-compose.env"
)

fail=0
warn() { echo "WARN: $*" >&2; }
die() { echo "ERROR: $*" >&2; fail=1; }

echo "==> Git: env files must not be tracked"
for f in "${ENV_CANDIDATES[@]}"; do
  rel="${f#${REPO_ROOT}/}"
  if git -C "${REPO_ROOT}" ls-files --error-unmatch "${rel}" >/dev/null 2>&1; then
    die "${rel} is tracked by git — run: git rm --cached ${rel}"
  fi
done

echo "==> Git: verify ignore rules"
for rel in paas/.env paas/frontend/docker-compose.env paas/frontend/.env; do
  if [[ -f "${REPO_ROOT}/${rel}" ]]; then
    if git -C "${REPO_ROOT}" check-ignore -q "${rel}" 2>/dev/null; then
      echo "  OK ignored: ${rel}"
    else
      die "${rel} exists but is NOT gitignored — update .gitignore"
    fi
  fi
done

echo "==> Filesystem permissions (owner read/write only)"
secure_mode() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  if [[ "${FIX}" == "--fix" ]]; then
    chmod 600 "$f" 2>/dev/null || warn "could not chmod 600 ${f}"
  fi
  if command -v stat >/dev/null 2>&1; then
    local mode=""
    if stat -c '%a' "$f" >/dev/null 2>&1; then
      mode="$(stat -c '%a' "$f")"
    elif stat -f '%OLp' "$f" >/dev/null 2>&1; then
      mode="$(stat -f '%OLp' "$f" | tail -c 4)"
    fi
    if [[ -n "${mode}" && "${mode}" != "600" && "${mode}" != "400" ]]; then
      warn "${f} mode=${mode} (want 600). Run: bash paas/scripts/secure-env-files.sh --fix"
    else
      echo "  OK mode ${mode:-?}: ${f}"
    fi
  fi
}
for f in "${ENV_CANDIDATES[@]}"; do
  secure_mode "$f"
done

echo "==> Placeholder / weak values in docker-compose.env"
ENV_FILE="${REPO_ROOT}/paas/frontend/docker-compose.env"
if [[ -f "${ENV_FILE}" ]]; then
  if grep -qE '^JWT_SECRET=change-this' "${ENV_FILE}" 2>/dev/null; then
    warn "JWT_SECRET still default in ${ENV_FILE}"
  fi
  if grep -qE '^GITOPS_REPO_TOKEN=ghp_your_' "${ENV_FILE}" 2>/dev/null; then
    warn "GITOPS_REPO_TOKEN still example placeholder"
  fi
  if grep -qE '^JENKINS_API_TOKEN=$' "${ENV_FILE}" 2>/dev/null; then
    warn "JENKINS_API_TOKEN is empty"
  fi
fi

echo "==> Kubernetes secret (lab)"
if command -v kubectl >/dev/null 2>&1 && kubectl get secret paas-frontend-env -n paas >/dev/null 2>&1; then
  echo "  OK secret/paas-frontend-env exists in namespace paas (not in git)"
else
  echo "  (skip) no paas-frontend-env secret — run sync-paas-frontend-env-k8s.sh on lab VM"
fi

if [[ "${fail}" -ne 0 ]]; then
  echo ""
  echo "Fix tracking: git rm --cached <file> && commit"
  echo "Permissions:  bash paas/scripts/secure-env-files.sh --fix"
  exit 1
fi
echo ""
echo "OK — env files are not in git; keep secrets only in docker-compose.env / K8s Secret."
