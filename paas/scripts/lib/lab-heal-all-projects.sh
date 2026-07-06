#!/usr/bin/env bash
# Lab script to heal all projects on VM cluster
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
DIR="${REPO_ROOT}/paas/scripts"
LIB="${SCRIPT_DIR}"
GITOPS="${GITOPS:-${HOME}/gitops}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
HEAL_SCRIPT="${DIR}/heal-project-deploy-lab.sh"
SKIP_MISSING_IMAGE="${SKIP_MISSING_IMAGE:-true}"

guess_port() {
  local project="$1" port="${2:-}"
  if [[ -n "${port}" && "${port}" != "0" ]]; then
    echo "${port}"
    return
  fi
  case "${project}" in
    *angular*|*vite*|*static*|*spa*|warda*) echo 80 ;;
    *python*|docker-demo*) echo 8000 ;;
    *) echo 3000 ;;
  esac
}

harbor_has_tag() {
  local project="$1" tag="$2"
  local user="${HARBOR_USER:-admin}" pass="${HARBOR_PASS:-Harbor12345}"
  if [[ -f "${ENV_FILE}" ]]; then
    user="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    pass="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    [[ -z "${user}" ]] && user="admin"
    [[ -z "${pass}" ]] && pass="Harbor12345"
  fi
  curl -s -u "${user}:${pass}" "http://${NODE_IP}:${HARBOR_PORT}/v2/paas/${project}/tags/list" 2>/dev/null \
    | python3 -c "import json,sys; t=json.load(sys.stdin).get('tags') or []; sys.exit(0 if '${tag}' in [str(x) for x in t] else 1)" 2>/dev/null
}

latest_harbor_tag() {
  local project="$1"
  local user="${HARBOR_USER:-admin}" pass="${HARBOR_PASS:-Harbor12345}"
  curl -s -u "${user}:${pass}" "http://${NODE_IP}:${HARBOR_PORT}/v2/paas/${project}/tags/list" 2>/dev/null \
    | python3 -c "
import json,sys
tags=[str(t) for t in (json.load(sys.stdin).get('tags') or [])]
nums=sorted([int(t) for t in tags if t.isdigit()])
print(nums[-1] if nums else (tags[-1] if tags else ''))
" 2>/dev/null || true
}

[[ -d "${GITOPS}/apps" ]] || { echo "ERROR: ${GITOPS}/apps missing — clone gitops to ~/gitops" >&2; exit 1; }
[[ -x "${HEAL_SCRIPT}" ]] || HEAL_SCRIPT="${DIR}/heal-project-deploy-lab.sh"

echo "=============================================="
echo " Heal ALL GitOps projects under ${GITOPS}/apps"
echo "=============================================="

ok=0
skip=0
fail=0

for app_dir in "${GITOPS}/apps"/*; do
  [[ -d "${app_dir}" ]] || continue
  project="$(basename "${app_dir}")"
  values="${app_dir}/values.yaml"
  [[ -f "${values}" ]] || { echo "SKIP ${project} (no values.yaml)"; skip=$((skip+1)); continue; }

  read -r tag port < <(python3 - "${values}" <<'PY'
import sys, yaml
from pathlib import Path
doc = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8")) or {}
img = doc.get("image") if isinstance(doc.get("image"), dict) else {}
tag = str(img.get("tag") or "").strip()
port = doc.get("service", {}).get("targetPort") if isinstance(doc.get("service"), dict) else None
print(tag or "", port or "")
PY
)
  tag="$(echo "${tag}" | xargs)"
  port="$(guess_port "${project}" "${port}")"

  if [[ -z "${tag}" ]]; then
    tag="$(latest_harbor_tag "${project}")"
  fi
  if [[ -z "${tag}" ]]; then
    echo "SKIP ${project} — no image tag in values.yaml and no Harbor tags"
    skip=$((skip+1))
    continue
  fi
  if ! harbor_has_tag "${project}" "${tag}"; then
    alt="$(latest_harbor_tag "${project}")"
    if [[ -n "${alt}" ]] && harbor_has_tag "${project}" "${alt}"; then
      echo "WARN ${project}: tag ${tag} missing in Harbor — using latest ${alt}"
      tag="${alt}"
    elif [[ "${SKIP_MISSING_IMAGE}" == "true" ]]; then
      echo "SKIP ${project} — Harbor has no paas/${project}:${tag}"
      skip=$((skip+1))
      continue
    fi
  fi

  echo ""
  echo "---------- ${project} :${tag} port=${port} ----------"
  if bash "${HEAL_SCRIPT}" "${project}" "${tag}" "${port}"; then
    ok=$((ok+1))
  else
    echo "FAIL ${project}" >&2
    fail=$((fail+1))
  fi
done

echo ""
echo "=============================================="
echo "Done: ok=${ok} skip=${skip} fail=${fail}"
echo "Traefik routing:"
echo "  bash paas/scripts/lib/lab-fix-traefik-app-routing.sh"
echo "=============================================="
[[ "${fail}" -eq 0 ]]
