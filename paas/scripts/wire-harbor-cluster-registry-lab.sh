#!/usr/bin/env bash
# Upsert in-cluster Harbor registry hosts for cosign verify from pods (NodePort often unreachable).
# Does NOT set HARBOR_REGISTRY_PUSH — use fix-harbor-jenkins-crane-push-lab.sh for crane push host.
set -euo pipefail

ENV_FILE="${1:?usage: wire-harbor-cluster-registry-lab.sh /path/to/docker-compose.env}"

upsert() {
  local key="$1" val="$2"
  if grep -q "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

REGISTRY_CLUSTER=""
NGINX_CLUSTER=""

if command -v kubectl >/dev/null 2>&1 && kubectl get ns harbor >/dev/null 2>&1; then
  if kubectl get svc harbor-nginx -n harbor >/dev/null 2>&1; then
    NGINX_CLUSTER="harbor-nginx.harbor.svc.cluster.local"
  elif kubectl get svc nginx -n harbor >/dev/null 2>&1; then
    NGINX_CLUSTER="nginx.harbor.svc.cluster.local"
  elif kubectl get svc harbor -n harbor >/dev/null 2>&1; then
    NGINX_CLUSTER="harbor.harbor.svc.cluster.local"
  fi
  if kubectl get svc harbor-registry -n harbor >/dev/null 2>&1; then
    PORT="$(kubectl get svc harbor-registry -n harbor -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo 5000)"
    REGISTRY_CLUSTER="harbor-registry.harbor.svc.cluster.local:${PORT}"
  fi
fi

if [[ -n "${REGISTRY_CLUSTER}" ]]; then
  upsert "HARBOR_REGISTRY_CLUSTER" "${REGISTRY_CLUSTER}"
  echo "OK: HARBOR_REGISTRY_CLUSTER=${REGISTRY_CLUSTER}"
fi
if [[ -n "${NGINX_CLUSTER}" ]]; then
  upsert "HARBOR_REGISTRY_NGINX_CLUSTER" "${NGINX_CLUSTER}"
  echo "OK: HARBOR_REGISTRY_NGINX_CLUSTER=${NGINX_CLUSTER}"
fi
