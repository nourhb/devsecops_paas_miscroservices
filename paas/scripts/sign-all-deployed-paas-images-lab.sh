#!/usr/bin/env bash
# Cosign-sign images currently running in PaaS project namespaces (Security UI: cosignSigned).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
PAAS_NS="${PAAS_NS:-paas}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${KEYDIR}/cosign.key" ]] || die "Missing ${KEYDIR}/cosign.key — run: bash paas/scripts/setup-security-lab.sh"
command -v cosign >/dev/null 2>&1 || die "Install cosign on the VM (apt or GitHub release)"

export COSIGN_PASSWORD=""

sign_refs_for_image() {
  local image="$1"
  local refs=("${image}")
  local external nginx
  external="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  nginx="$(grep '^HARBOR_REGISTRY_NGINX_CLUSTER=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- | tr -d '"')"
  if [[ -n "${external}" && -n "${nginx}" && "${image}" == "${external}/"* ]]; then
    refs+=("${image/${external}/${nginx}}")
  fi
  local r
  local -a seen=()
  for r in "${refs[@]}"; do
    [[ " ${seen[*]:-} " == *" ${r} "* ]] && continue
    seen+=("${r}")
    cosign sign --yes --allow-insecure-registry --key "${KEYDIR}/cosign.key" "${r}" || return 1
  done
}

echo "==> Collect deployed images from Postgres projects"
mapfile -t ROWS < <(kubectl exec -n "${PAAS_NS}" deploy/postgres -- psql -U postgres -d paas -tAc \
  "SELECT \"projectName\", namespace FROM \"Project\" WHERE \"deletedAt\" IS NULL ORDER BY \"projectName\";" 2>/dev/null \
  | tr -d '\r' | grep '|' || true)

if [[ ${#ROWS[@]} -eq 0 ]]; then
  die "No projects in database"
fi

signed=0
skipped=0
failed=0

for row in "${ROWS[@]}"; do
  name="${row%%|*}"
  ns="${row##*|}"
  ns="${ns// /}"
  [[ -z "${name}" || -z "${ns}" ]] && continue
  image="$(kubectl get deploy -n "${ns}" -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  if [[ -z "${image}" || "${image}" != *:* ]]; then
    echo "SKIP ${name}: no deployment image in namespace ${ns}"
    skipped=$((skipped + 1))
    continue
  fi
  if cosign verify --key "${KEYDIR}/cosign.pub" --allow-insecure-registry "${image}" >/dev/null 2>&1; then
    echo "OK   ${name}: already signed ${image}"
    signed=$((signed + 1))
    continue
  fi
  echo "==> Sign ${name}: ${image} (+ in-cluster Harbor ref when configured)"
  if sign_refs_for_image "${image}"; then
    signed=$((signed + 1))
  else
    echo "FAIL ${name}: cosign sign failed for ${image}" >&2
    failed=$((failed + 1))
  fi
done

echo ""
echo "Done: signed/already=${signed} skipped=${skipped} failed=${failed}"
[[ "${failed}" -eq 0 ]] || exit 1

if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  echo "==> Restart frontend so Security API picks up cosign mount (if changed)"
  kubectl rollout restart deployment/frontend -n "${PAAS_NS}" >/dev/null 2>&1 || true
fi

echo "Refresh each project's Security page in the PaaS UI."
