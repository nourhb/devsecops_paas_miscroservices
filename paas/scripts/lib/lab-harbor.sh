#!/usr/bin/env bash
# Lab script to harbor on VM cluster
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_NS="${HARBOR_NS:-harbor}"
HARBOR_RELEASE="${HARBOR_RELEASE:-harbor}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
REGISTRY="${HARBOR_HOST}:${HARBOR_NODEPORT}"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"

harbor_normalize_env() {
  [[ -f "${ENV_FILE}" ]] || return 0
  python3 - "${ENV_FILE}" "${NODE_IP}" "${HARBOR_NODEPORT}" <<'PY'
import re
import sys
from pathlib import Path

path, node_ip, port = sys.argv[1:4]
nip_host = f"harbor.{node_ip}.nip.io:{port}"
nip_base = f"http://{nip_host}"
text = Path(path).read_text(encoding="utf-8")
lines = text.splitlines()
out = []
ipv4 = re.compile(r"^(\d{1,3}\.){3}\d{1,3}(:\d+)?$")
changed = False
for line in lines:
    if line.startswith("HARBOR_REGISTRY="):
        val = line.split("=", 1)[1].strip().strip('"').strip("'")
        host = val.replace("http://", "").replace("https://", "").split("/")[0]
        if ipv4.match(host):
            line = f"HARBOR_REGISTRY={nip_host}"
            changed = True
    elif line.startswith("HARBOR_BASE_URL="):
        val = line.split("=", 1)[1].strip().strip('"').strip("'")
        host = val.replace("http://", "").replace("https://", "").split("/")[0]
        if ipv4.match(host):
            line = f"HARBOR_BASE_URL={nip_base}"
            changed = True
    out.append(line)
if changed:
    Path(path).write_text("\n".join(out) + ("\n" if text.endswith("\n") else ""), encoding="utf-8")
    print(f"OK normalized Harbor env in {path}")
PY
}

harbor_configure_k3s() {
  local registries_file="${REGISTRIES_FILE:-/etc/rancher/k3s/registries.yaml}"
  local harbor_user="${HARBOR_USER:-admin}"
  local harbor_pass="${HARBOR_PASS:-Harbor12345}"
  sudo mkdir -p "$(dirname "${registries_file}")"
  sudo tee "${registries_file}" >/dev/null <<EOF
mirrors:
  "${HARBOR_HOST}:${HARBOR_NODEPORT}":
    endpoint:
      - "http://${HARBOR_HOST}:${HARBOR_NODEPORT}"
  "${NODE_IP}:${HARBOR_NODEPORT}":
    endpoint:
      - "http://${NODE_IP}:${HARBOR_NODEPORT}"
configs:
  "${HARBOR_HOST}:${HARBOR_NODEPORT}":
    auth:
      username: ${harbor_user}
      password: ${harbor_pass}
    tls:
      insecure_skip_verify: true
  "${NODE_IP}:${HARBOR_NODEPORT}":
    auth:
      username: ${harbor_user}
      password: ${harbor_pass}
    tls:
      insecure_skip_verify: true
EOF
  echo "OK wrote ${registries_file}"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet k3s 2>/dev/null; then
      echo "==> Restart k3s (control-plane)"
      sudo systemctl restart k3s
    fi
    if systemctl is-active --quiet k3s-agent 2>/dev/null; then
      echo "==> Restart k3s-agent"
      sudo systemctl restart k3s-agent
    fi
  fi
  echo "OK: Harbor HTTP mirrors for ${NODE_IP}:${HARBOR_NODEPORT} and ${HARBOR_HOST}:${HARBOR_NODEPORT}"
}

harbor_fix_cosign_realm() {
  local external_url="http://${HARBOR_HOST}:${HARBOR_NODEPORT}"
  if command -v helm >/dev/null 2>&1 && helm status "${HARBOR_RELEASE}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
    helm upgrade "${HARBOR_RELEASE}" harbor/harbor -n "${HARBOR_NS}" --reuse-values \
      --set "externalURL=${external_url}"
  else
    echo "WARN: helm release ${HARBOR_RELEASE} not found in ${HARBOR_NS}" >&2
    return 1
  fi
}

harbor_probe() {
  curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 20 "http://${REGISTRY}/v2/" 2>/dev/null || echo "000"
}

harbor_load_creds() {
  HARBOR_USER="${HARBOR_USER:-admin}"
  HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
  if [[ "${HARBOR_CREDS_FROM_SECRET:-}" == "1" ]]; then
    return 0
  fi
  if [[ -f "${ENV_FILE}" ]]; then
    local u p
    u="$(grep -E '^HARBOR_USERNAME=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    p="$(grep -E '^HARBOR_PASSWORD=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    [[ -z "${u}" ]] && u="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    [[ -z "${p}" ]] && p="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
    [[ -n "${u}" ]] && HARBOR_USER="${u}"
    [[ -n "${p}" ]] && HARBOR_PASS="${p}"
  fi
}

harbor_read_admin_password() {
  harbor_load_creds
  local from_secret=""
  if command -v kubectl >/dev/null 2>&1; then
    from_secret="$(kubectl get secret -n "${HARBOR_NS}" harbor-core \
      -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    if [[ -z "${from_secret}" ]]; then
      from_secret="$(kubectl get secret -n "${HARBOR_NS}" "${HARBOR_RELEASE}-core" \
        -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    fi
  fi
  if [[ -n "${from_secret}" ]]; then
    HARBOR_PASS="${from_secret}"
    HARBOR_CREDS_FROM_SECRET=1
    echo "OK: Harbor admin password from k8s secret (${#from_secret} chars)"
  else
    echo "WARN: using Harbor password from env/default"
  fi
}

harbor_patch_env_file() {
  local file="$1"
  [[ -f "${file}" ]] || touch "${file}"
  local changed=0
  for kv in "HARBOR_USERNAME=${HARBOR_USER}" "HARBOR_PASSWORD=${HARBOR_PASS}" \
            "HARBOR_USER=${HARBOR_USER}" "HARBOR_PASS=${HARBOR_PASS}" \
            "HARBOR_REGISTRY=${REGISTRY}" "HARBOR_BASE_URL=http://${REGISTRY}"; do
    local key="${kv%%=*}" val="${kv#*=}"
    if grep -qE "^${key}=" "${file}" 2>/dev/null; then
      sed -i "s|^${key}=.*|${key}=${val}|" "${file}"
    else
      echo "${key}=${val}" >> "${file}"
    fi
    changed=1
  done
  [[ "${changed}" == "1" ]] && echo "OK: patched ${file} (Harbor creds + registry)"
}

harbor_api_bases() {
  printf '%s\n' "http://${REGISTRY}" "http://${NODE_IP}:${HARBOR_NODEPORT}"
}

harbor_verify_push_token() {
  local user="$1" pass="$2" repo="$3"
  local scope="repository:${repo}:pull,push"
  local base tok
  for base in $(harbor_api_bases); do
    tok="$(curl -sS -u "${user}:${pass}" \
      "${base}/service/token?service=harbor-registry&scope=${scope}" 2>/dev/null \
      | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 || true)"
    if [[ -n "${tok}" ]]; then
      echo "OK: Harbor push token for ${repo} via ${base}"
      return 0
    fi
    echo "WARN: no push token from ${base} scope=${scope}" >&2
  done
  return 1
}

harbor_ensure_paas_project() {
  local user="${HARBOR_USER:-admin}"
  local pass="${HARBOR_PASS:-Harbor12345}"
  local proj="${HARBOR_PROJECT:-paas}"
  local base code body
  for base in $(harbor_api_bases); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${user}:${pass}" \
      "${base}/api/v2.0/projects/${proj}" 2>/dev/null || echo 000)"
    if [[ "${code}" == "200" ]]; then
      echo "OK: Harbor project ${proj} exists (${base})"
      harbor_verify_push_token "${user}" "${pass}" "${proj}/_probe" && return 0 || true
      return 0
    fi
    echo "==> create Harbor project ${proj} at ${base} (GET HTTP ${code})"
    for payload in \
      "{\"project_name\":\"${proj}\",\"metadata\":{\"public\":\"true\"}}" \
      "{\"project_name\":\"${proj}\",\"public\":true}"; do
      body="$(curl -sS -u "${user}:${pass}" -X POST "${base}/api/v2.0/projects" \
        -H 'Content-Type: application/json' -d "${payload}" 2>/dev/null || true)"
      code="$(curl -sS -o /dev/null -w '%{http_code}' -u "${user}:${pass}" \
        "${base}/api/v2.0/projects/${proj}" 2>/dev/null || echo 000)"
      if [[ "${code}" == "200" ]]; then
        echo "OK: Harbor project ${proj} ready (${base})"
        return 0
      fi
      if echo "${body}" | grep -qi 'already exists\|conflict'; then
        echo "OK: Harbor project ${proj} already exists (${base})"
        return 0
      fi
    done
    echo "WARN: create project ${proj} at ${base} failed (last GET HTTP ${code}) body=${body:0:120}" >&2
  done
  return 1
}

harbor_test_crane_push() {
  local user="${HARBOR_USER:-admin}"
  local pass="${HARBOR_PASS:-Harbor12345}"
  local proj="${HARBOR_PROJECT:-paas}"
  local repo="${proj}/paas-harbor-push-probe"
  local tag="probe-$(date +%s)"
  local ref_ip="${NODE_IP}:${HARBOR_NODEPORT}/${repo}:${tag}"
  local ref_nip="${REGISTRY}/${repo}:${tag}"
  local jpod jns="${JENKINS_NS:-cicd}"
  jpod="$(kubectl get pods -n "${jns}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | grep -v Terminating | head -1 || true)"
  [[ -n "${jpod}" ]] || { echo "WARN: no Jenkins pod for crane probe"; return 1; }
  echo "==> crane push probe from ${jns}/${jpod} → ${ref_ip}"
  kubectl exec -n "${jns}" "${jpod}" -c jenkins --request-timeout=180s -- bash -s <<EOS || return 1
set -eu
find_crane() {
  for c in /var/jenkins_home/.jenkins-paas-cache/crane/*/crane /var/jenkins_home/bin/crane; do
    [ -x "\$c" ] && { printf '%s' "\$c"; return 0; }
  done
  command -v crane 2>/dev/null || true
}
CRANE=\$(find_crane)
[ -n "\$CRANE" ] || { echo "ERROR: crane missing"; exit 1; }
export DOCKER_CONFIG="/tmp/paas-harbor-probe-\$\$"
mkdir -p "\$DOCKER_CONFIG"
trap 'rm -rf "\$DOCKER_CONFIG"' EXIT
echo "${HARBOR_PASS}" | "\$CRANE" auth login "${NODE_IP}:${HARBOR_NODEPORT}" -u "${HARBOR_USER}" --password-stdin --insecure
echo "${HARBOR_PASS}" | "\$CRANE" auth login "${REGISTRY}" -u "${HARBOR_USER}" --password-stdin --insecure || true
"\$CRANE" pull --insecure mirror.gcr.io/library/alpine:3.20 /tmp/paas-probe.tar
"\$CRANE" push --insecure /tmp/paas-probe.tar "${ref_ip}"
"\$CRANE" digest --insecure "${ref_ip}"
rm -f /tmp/paas-probe.tar
EOS
  echo "OK: crane push probe succeeded (${ref_ip})"
}

harbor_fix_push() {
  echo "=============================================="
  echo " Harbor push fix (RBAC + robot + crane probe)"
  echo "=============================================="
  if [[ -f "${SCRIPT_DIR}/harbor-push-rbac-fix.py" ]]; then
    python3 "${SCRIPT_DIR}/harbor-push-rbac-fix.py" || return 1
    harbor_load_creds
  else
    harbor_normalize_env || true
    harbor_read_admin_password
    harbor_fix_cosign_realm || true
    harbor_recover || true
    harbor_ensure_paas_project || return 1
  fi
  harbor_patch_env_file "${ENV_FILE}"
  [[ -f "${REPO_ROOT}/paas/frontend/.env" ]] && harbor_patch_env_file "${REPO_ROOT}/paas/frontend/.env"
  if [[ -f "${SCRIPT_DIR}/sync-harbor-jenkins-job-params.py" ]]; then
    python3 "${SCRIPT_DIR}/sync-harbor-jenkins-job-params.py" || true
  fi
  harbor_test_crane_push || {
    echo "ERROR: crane push probe failed" >&2
    return 1
  }
  echo "OK: Harbor push path verified — trigger NEW paas-deploy build"
}

harbor_recover() {
  echo "==> Harbor registry recover (${REGISTRY})"
  harbor_normalize_env || true
  if [[ -f "${SCRIPT_DIR}/lab-harbor-db-heal.sh" ]]; then
    bash "${SCRIPT_DIR}/lab-harbor-db-heal.sh" || true
  fi
  harbor_fix_cosign_realm || true
  harbor_ensure_paas_project || true
  local hc
  hc="$(harbor_probe)"
  if [[ "${hc}" == "200" || "${hc}" == "401" ]]; then
    echo "OK: Harbor /v2/ already healthy (HTTP ${hc})"
    return 0
  fi
  echo "Harbor /v2/ HTTP ${hc} — restarting core registry workloads"
  kubectl get pods -n "${HARBOR_NS}" -o wide 2>/dev/null || true
  for deploy in harbor-nginx harbor-registry harbor-core; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      echo "==> rollout restart deployment/${deploy} -n ${HARBOR_NS}"
      kubectl rollout restart "deployment/${deploy}" -n "${HARBOR_NS}" || true
    fi
  done
  for deploy in harbor-nginx harbor-registry harbor-core; do
    if kubectl get deployment "${deploy}" -n "${HARBOR_NS}" >/dev/null 2>&1; then
      kubectl rollout status "deployment/${deploy}" -n "${HARBOR_NS}" --timeout=300s || true
    fi
  done
  for i in $(seq 1 30); do
    hc="$(harbor_probe)"
    if [[ "${hc}" == "200" || "${hc}" == "401" ]]; then
      echo "OK: Harbor /v2/ recovered (HTTP ${hc})"
      return 0
    fi
    echo "wait ${i}/30 — Harbor /v2/ HTTP ${hc}"
    sleep 10
  done
  echo "ERROR: Harbor still unhealthy at http://${REGISTRY}/v2/" >&2
  kubectl get pods -n "${HARBOR_NS}" 2>/dev/null || true
  kubectl get events -n "${HARBOR_NS}" --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
  return 1
}

harbor_bootstrap() {
  harbor_normalize_env || true
  harbor_configure_k3s || true
  harbor_recover || true
  harbor_fix_cosign_realm || true
}

cmd="${1:-recover}"
case "${cmd}" in
  normalize) harbor_normalize_env ;;
  configure) harbor_configure_k3s ;;
  fix-realm) harbor_fix_cosign_realm ;;
  ensure-project) harbor_ensure_paas_project ;;
  fix-push) harbor_fix_push ;;
  recover) harbor_recover ;;
  bootstrap) harbor_bootstrap ;;
  *)
    echo "usage: lab-harbor.sh [normalize|configure|fix-realm|ensure-project|fix-push|recover|bootstrap]" >&2
    exit 1 ;;
esac
