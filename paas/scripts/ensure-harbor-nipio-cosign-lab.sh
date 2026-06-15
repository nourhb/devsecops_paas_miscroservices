#!/usr/bin/env bash
# Copy image + cosign signature to harbor.<nip>.nip.io (Kyverno needs signatures on the nip.io ref).
set -euo pipefail
PROJECT_SLUG="${1:?usage: ensure-harbor-nipio-cosign-lab.sh <slug> <tag>}"
IMAGE_TAG="${2:?usage: ensure-harbor-nipio-cosign-lab.sh <slug> <tag>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_PORT="${HARBOR_NODEPORT:-30002}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
SRC="${NODE_IP}:${HARBOR_PORT}/paas/${PROJECT_SLUG}:${IMAGE_TAG}"
DST="${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_SLUG}:${IMAGE_TAG}"
JOB_NS="${COSIGN_JOB_NS:-cicd}"
COSIGN_IMAGE="${COSIGN_JOB_IMAGE:-ghcr.io/sigstore/cosign/cosign:v2.4.1}"

load_env() {
  HARBOR_USER="${HARBOR_USER:-admin}"
  HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
  COSIGN_KEY="${COSIGN_PRIVATE_KEY:-}"
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
  COSIGN_PUB="${COSIGN_PUBLIC_KEY:-}"
  [[ -f "${ENV_FILE}" ]] || return 0
  HARBOR_USER="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  HARBOR_PASS="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${HARBOR_USER}" ]] && HARBOR_USER="admin"
  [[ -z "${HARBOR_PASS}" ]] && HARBOR_PASS="Harbor12345"
  [[ -z "${COSIGN_KEY}" ]] && COSIGN_KEY="$(grep -E '^COSIGN_PRIVATE_KEY=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${COSIGN_PASSWORD}" ]] && COSIGN_PASSWORD="$(grep -E '^COSIGN_PASSWORD=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${COSIGN_PUB}" ]] && COSIGN_PUB="$(grep -E '^COSIGN_PUBLIC_KEY=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  if [[ -n "${COSIGN_KEY}" && "${COSIGN_KEY}" == *'\\n'* ]]; then
    COSIGN_KEY="$(printf '%b' "${COSIGN_KEY}")"
  fi
  if [[ -n "${COSIGN_PUB}" && "${COSIGN_PUB}" == *'\\n'* ]]; then
    COSIGN_PUB="$(printf '%b' "${COSIGN_PUB}")"
  fi
}

load_cosign_key_from_jenkins() {
  local ns pod key
  ns="$(kubectl get pods -A 2>/dev/null | awk '/jenkins/ && !/Terminating/ {print $1; exit}')"
  pod="$(kubectl get pods -A 2>/dev/null | awk '/jenkins/ && !/Terminating/ {print $2; exit}')"
  [[ -n "${ns}" && -n "${pod}" ]] || return 1
  key="$(kubectl exec -n "${ns}" "${pod}" -- cat /var/jenkins_home/cosign-lab/cosign.key 2>/dev/null || true)"
  [[ -n "${key}" ]] || return 1
  COSIGN_KEY="${key}"
  echo "OK: loaded cosign key from ${ns}/${pod}:/var/jenkins_home/cosign-lab/cosign.key"
}

cosign_verify_dst() {
  [[ -n "${COSIGN_PUB}" ]] || return 1
  export COSIGN_PUBLIC_KEY="${COSIGN_PUB}"
  export COSIGN_EXPERIMENTAL=1
  cosign verify --allow-insecure-registry --key env://COSIGN_PUBLIC_KEY "${DST}" >/dev/null 2>&1
}

run_local() {
  command -v cosign >/dev/null 2>&1 || return 1
  export COSIGN_PRIVATE_KEY="${COSIGN_KEY}"
  export COSIGN_PASSWORD="${COSIGN_PASSWORD}"
  export COSIGN_EXPERIMENTAL=1
  if cosign_verify_dst 2>/dev/null; then
    echo "OK: signature already valid on ${DST}"
    return 0
  fi
  echo "==> cosign copy (local) ${SRC} -> ${DST}"
  cosign copy --allow-insecure-registry --force "${SRC}" "${DST}" 2>/dev/null || true
  if cosign_verify_dst 2>/dev/null; then
    echo "OK: cosign copy transferred signature"
    return 0
  fi
  if command -v crane >/dev/null 2>&1; then
    crane auth login "${HARBOR_HOST}:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null \
      || crane auth login "${NODE_IP}:${HARBOR_PORT}" -u "${HARBOR_USER}" -p "${HARBOR_PASS}" 2>/dev/null || true
    crane copy "${SRC}" "${DST}" 2>/dev/null || crane tag "${SRC}" "${DST}" 2>/dev/null || true
  fi
  cosign sign --yes --allow-insecure-registry --key env://COSIGN_PRIVATE_KEY "${DST}"
  cosign_verify_dst
}

run_k8s_job() {
  [[ -n "${COSIGN_KEY}" ]] || return 1
  local job="paas-cosign-nipio-${PROJECT_SLUG}-$(date +%s)"
  local key_secret="paas-cosign-signing-key"
  local auth_secret="paas-harbor-cosign-auth"
  kubectl create namespace "${JOB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic "${key_secret}" -n "${JOB_NS}" \
    --from-literal=cosign.key="${COSIGN_KEY}" \
    --from-literal=cosign.password="${COSIGN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry "${auth_secret}" -n "${JOB_NS}" \
    --docker-server="${HARBOR_HOST}:${HARBOR_PORT}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  # second auth for IP registry (source image)
  kubectl create secret docker-registry "${auth_secret}-ip" -n "${JOB_NS}" \
    --docker-server="${NODE_IP}:${HARBOR_PORT}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  echo "==> cosign Job ${JOB_NS}/${job}"
  kubectl apply -n "${JOB_NS}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${JOB_NS}
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ${auth_secret}
      volumes:
        - name: cosign-key
          secret:
            secretName: ${key_secret}
        - name: docker-config
          secret:
            secretName: ${auth_secret}
            items:
              - key: .dockerconfigjson
                path: config.json
      containers:
        - name: cosign
          image: ${COSIGN_IMAGE}
          volumeMounts:
            - name: cosign-key
              mountPath: /cosign
              readOnly: true
            - name: docker-config
              mountPath: /root/.docker
              readOnly: true
          env:
            - name: COSIGN_EXPERIMENTAL
              value: "1"
            - name: COSIGN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: ${key_secret}
                  key: cosign.password
                  optional: true
          command: ["/bin/sh", "-ce"]
          args:
            - |
              set -e
              export COSIGN_PRIVATE_KEY="\$(cat /cosign/cosign.key)"
              SRC='${SRC}'
              DST='${DST}'
              echo "[cosign-job] copy signatures \${SRC} -> \${DST}"
              cosign copy --allow-insecure-registry --force "\${SRC}" "\${DST}" || true
              if cosign tree "\${DST}" 2>/dev/null | grep -q signature; then
                echo OK verify tree has signature
                exit 0
              fi
              echo "[cosign-job] install crane + retag"
              ARCH=\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
              wget -q -O /tmp/crane.tgz "https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_\${ARCH}.tar.gz"
              tar -xzf /tmp/crane.tgz -C /usr/local/bin crane 2>/dev/null || tar -xzf /tmp/crane.tgz -C /tmp && install /tmp/crane /usr/local/bin/crane
              crane auth login '${HARBOR_HOST}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' || \\
                crane auth login '${NODE_IP}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}'
              crane copy "\${SRC}" "\${DST}" || crane tag "\${SRC}" "\${DST}"
              echo "[cosign-job] sign \${DST}"
              cosign sign --yes --allow-insecure-registry --key env://COSIGN_PRIVATE_KEY "\${DST}"
              echo OK signed
EOF
  if ! kubectl wait --for=condition=complete "job/${job}" -n "${JOB_NS}" --timeout=300s; then
    echo "ERROR: cosign job failed — logs:" >&2
    kubectl logs "job/${job}" -n "${JOB_NS}" --tail=80 2>/dev/null || true
    kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi
  kubectl logs "job/${job}" -n "${JOB_NS}" --tail=40
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
  return 0
}

load_env
[[ -n "${COSIGN_KEY}" ]] || load_cosign_key_from_jenkins || true
if [[ -z "${COSIGN_KEY}" ]]; then
  echo "ERROR: COSIGN_PRIVATE_KEY missing in ${ENV_FILE} and not found on Jenkins pod" >&2
  exit 1
fi

echo "==> Ensure cosign signature on ${DST}"
if run_local; then
  echo "OK: ${DST} signed (local cosign)"
  exit 0
fi
if run_k8s_job; then
  echo "OK: ${DST} signed (k8s job)"
  exit 0
fi
echo "ERROR: could not sign ${DST}" >&2
exit 1
