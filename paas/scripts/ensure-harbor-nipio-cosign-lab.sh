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
JENKINS_NS="${JENKINS_NS:-cicd}"

load_env() {
  HARBOR_USER="${HARBOR_USER:-admin}"
  HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
  [[ -f "${ENV_FILE}" ]] || return 0
  HARBOR_USER="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  HARBOR_PASS="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${HARBOR_USER}" ]] && HARBOR_USER="admin"
  [[ -z "${HARBOR_PASS}" ]] && HARBOR_PASS="Harbor12345"
  [[ -z "${COSIGN_PASSWORD}" ]] && COSIGN_PASSWORD="$(grep -E '^COSIGN_PASSWORD=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
}

jenkins_pod() {
  kubectl get pods -n "${JENKINS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | grep -v Terminating | head -1 || true
}

# Shared shell run inside Jenkins (HTTP Harbor + digest refs — tag-only sign hits HTTPS and fails).
jenkins_cosign_script() {
  cat <<SCRIPT
set -e
CRANE=''
for c in /var/jenkins_home/.jenkins-paas-cache/crane/*/crane /var/jenkins_home/bin/crane; do
  [ -x "\$c" ] && CRANE="\$c" && break
done
[ -n "\$CRANE" ] || CRANE=\$(command -v crane 2>/dev/null || true)
COSIGN=/var/jenkins_home/bin/cosign
[ -x "\$COSIGN" ] || COSIGN=\$(command -v cosign 2>/dev/null || true)
KEY='/var/jenkins_home/cosign-lab/cosign.key'
[ -x "\$CRANE" ] && [ -x "\$COSIGN" ] && [ -f "\$KEY" ] || { echo "missing crane/cosign/key"; exit 1; }
export COSIGN_EXPERIMENTAL=1
"\$CRANE" auth login '${HARBOR_HOST}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure \\
  || "\$CRANE" auth login '${NODE_IP}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure
if ! "\$CRANE" digest --insecure '${DST}' >/dev/null 2>&1; then
  echo "[cosign-lab] crane copy ${SRC} -> ${DST}"
  "\$CRANE" copy --insecure '${SRC}' '${DST}' || "\$CRANE" tag --insecure '${SRC}' '${DST}'
fi
SRC_D=\$("\$CRANE" digest --insecure '${SRC}' | tr -d '\\r\\n')
DST_D='${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_SLUG}@'\${SRC_D#*@}
echo "[cosign-lab] SRC_D=\$SRC_D"
echo "[cosign-lab] DST_D=\$DST_D"
if "\$COSIGN" tree "\$DST_D" 2>/dev/null | grep -qi signature; then
  echo "OK: signature already on \$DST_D"
  exit 0
fi
echo "[cosign-lab] cosign copy signatures"
"\$COSIGN" copy --allow-insecure-registry --force "\$SRC_D" "\$DST_D" || true
if "\$COSIGN" tree "\$DST_D" 2>/dev/null | grep -qi signature; then
  echo "OK: cosign copy transferred signature"
  "\$COSIGN" tree "\$DST_D" 2>/dev/null | head -8 || true
  exit 0
fi
echo "[cosign-lab] cosign sign digest (HTTP Harbor)"
COSIGN_PASSWORD='${COSIGN_PASSWORD}' "\$COSIGN" sign --yes --allow-insecure-registry --key "\$KEY" "\$DST_D"
"\$COSIGN" tree "\$DST_D" 2>/dev/null | head -8 || true
echo OK signed
SCRIPT
}

run_via_jenkins() {
  local pod
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  echo "==> crane/cosign via ${JENKINS_NS}/${pod} (digest ref)"
  kubectl exec -n "${JENKINS_NS}" "${pod}" -- sh -ce "$(jenkins_cosign_script)"
}

run_k8s_job() {
  local key pod job key_secret auth_secret
  pod="$(jenkins_pod)"
  key="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- cat /var/jenkins_home/cosign-lab/cosign.key 2>/dev/null || true)"
  [[ -n "${key}" ]] || return 1
  job="paas-cosign-nipio-${PROJECT_SLUG}-$(date +%s)"
  key_secret="paas-cosign-signing-key"
  auth_secret="paas-harbor-cosign-auth"
  kubectl create namespace "${JOB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic "${key_secret}" -n "${JOB_NS}" \
    --from-literal=cosign.key="${key}" \
    --from-literal=cosign.password="${COSIGN_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry "${auth_secret}" -n "${JOB_NS}" \
    --docker-server="${HARBOR_HOST}:${HARBOR_PORT}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "==> cosign Job ${JOB_NS}/${job}"
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
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
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        fsGroup: 65532
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
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: cosign-key
              mountPath: /cosign
              readOnly: true
            - name: docker-config
              mountPath: /home/nonroot/.docker
              readOnly: true
          env:
            - name: COSIGN_EXPERIMENTAL
              value: "1"
            - name: HOME
              value: /home/nonroot
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
              ARCH=\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
              wget -q -O /tmp/crane.tgz "https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_\${ARCH}.tar.gz"
              tar -xzf /tmp/crane.tgz -C /usr/local/bin crane 2>/dev/null || tar -xzf /tmp/crane.tgz -C /tmp && install /tmp/crane /usr/local/bin/crane
              crane auth login '${HARBOR_HOST}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure
              SRC='${SRC}'
              DST='${DST}'
              SRC_D=\$(crane digest --insecure "\${SRC}" | tr -d '\\r\\n')
              DST_D='${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_SLUG}@'\${SRC_D#*@}
              crane copy --insecure "\${SRC}" "\${DST}" 2>/dev/null || true
              cosign copy --allow-insecure-registry --force "\${SRC_D}" "\${DST_D}" || true
              if cosign tree "\${DST_D}" 2>/dev/null | grep -qi signature; then echo OK copy; exit 0; fi
              cosign sign --yes --allow-insecure-registry --key env://COSIGN_PRIVATE_KEY "\${DST_D}"
              cosign tree "\${DST_D}" | head -5
EOF
  if ! kubectl wait --for=condition=complete "job/${job}" -n "${JOB_NS}" --timeout=300s; then
    kubectl logs "job/${job}" -n "${JOB_NS}" --tail=80 2>/dev/null || true
    kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi
  kubectl logs "job/${job}" -n "${JOB_NS}" --tail=40
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

load_env
echo "==> Ensure cosign signature on ${DST} (from ${SRC})"
if run_via_jenkins; then
  echo "OK: signed via Jenkins pod"
  exit 0
fi
echo "WARN: Jenkins cosign failed — trying k8s Job" >&2
if run_k8s_job; then
  echo "OK: signed via k8s Job"
  exit 0
fi
echo "ERROR: could not sign ${DST}" >&2
exit 1
