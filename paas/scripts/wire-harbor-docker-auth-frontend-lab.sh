#!/usr/bin/env bash
# Mount Harbor docker config.json into frontend pod so cosign can pull signatures (same as host ~/.docker).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"
PATCH_FILE="/tmp/paas-frontend-docker-auth-patch-$$.yaml"
CONFIG_JSON="/tmp/paas-harbor-docker-config-$$.json"

die() { echo "ERROR: $*" >&2; exit 1; }
cleanup() { rm -f "${PATCH_FILE}" "${CONFIG_JSON}"; }
trap cleanup EXIT

[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}"
command -v kubectl >/dev/null 2>&1 || die "kubectl required"

HARBOR_USER="$(grep '^HARBOR_USERNAME=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
HARBOR_PASS="$(grep '^HARBOR_PASSWORD=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
EXTERNAL="$(grep '^HARBOR_REGISTRY=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"')"
NGINX="$(grep '^HARBOR_REGISTRY_NGINX_CLUSTER=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' || true)"
CLUSTER="$(grep '^HARBOR_REGISTRY_CLUSTER=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' || true)"

[[ -n "${HARBOR_USER}" && -n "${HARBOR_PASS}" ]] || die "HARBOR_USERNAME / HARBOR_PASSWORD missing in ${ENV_FILE}"

AUTH_B64="$(printf '%s:%s' "${HARBOR_USER}" "${HARBOR_PASS}" | base64 | tr -d '\n')"

python3 - "${CONFIG_JSON}" "${AUTH_B64}" "${HARBOR_USER}" "${HARBOR_PASS}" "${EXTERNAL}" "${NGINX}" "${CLUSTER}" <<'PY'
import json, sys
out, auth, user, password, external, nginx, cluster = sys.argv[1:8]
hosts = []
for h in (nginx, external, cluster):
    h = (h or "").strip()
    if h and h not in hosts:
        hosts.append(h)
entry = {"auth": auth, "username": user, "password": password}
auths = {host: dict(entry) for host in hosts}
with open(out, "w", encoding="utf-8") as f:
    json.dump({"auths": auths}, f, indent=2)
print("OK: docker config.json hosts:", ", ".join(sorted(auths.keys())))
PY

echo "==> Secret harbor-docker-config (cosign registry auth for frontend pod)"
kubectl create secret generic harbor-docker-config \
  --from-file=config.json="${CONFIG_JSON}" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" >/dev/null 2>&1 || die "deployment/${DEPLOY_NAME} not found"

cat > "${PATCH_FILE}" <<PATCH
spec:
  template:
    spec:
      volumes:
        - name: harbor-docker-config
          secret:
            secretName: harbor-docker-config
            defaultMode: 292
      containers:
        - name: ${DEPLOY_NAME}
          env:
            - name: DOCKER_CONFIG
              value: /etc/docker
          volumeMounts:
            - name: harbor-docker-config
              mountPath: /etc/docker
              readOnly: true
PATCH

kubectl patch deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" --type=strategic --patch-file="${PATCH_FILE}"
kubectl rollout restart "deployment/${DEPLOY_NAME}" -n "${PAAS_NS}"
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s

if kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- test -r /etc/docker/config.json; then
  echo "OK: frontend pod has /etc/docker/config.json (DOCKER_CONFIG=/etc/docker)"
else
  die "/etc/docker/config.json not readable in frontend pod"
fi
