#!/usr/bin/env bash
# Copy image + cosign .sig artifact to harbor.<nip>.nip.io (Kyverno verifies nip.io ref).
# cosign copy/attach/sign always probes nip.io over HTTPS — use crane --insecure for .sig copy.
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
SRC_REPO="${NODE_IP}:${HARBOR_PORT}/paas/${PROJECT_SLUG}"
DST_REPO="${HARBOR_HOST}:${HARBOR_PORT}/paas/${PROJECT_SLUG}"
JOB_NS="${COSIGN_JOB_NS:-cicd}"
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
[ -x "\$CRANE" ] || { echo "missing crane"; exit 1; }
export COSIGN_EXPERIMENTAL=1
"\$CRANE" auth login '${HARBOR_HOST}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure \\
  || "\$CRANE" auth login '${NODE_IP}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure
if ! "\$CRANE" digest --insecure '${DST}' >/dev/null 2>&1; then
  echo "[cosign-lab] crane copy image ${SRC} -> ${DST}"
  "\$CRANE" copy --insecure '${SRC}' '${DST}' || "\$CRANE" tag --insecure '${SRC}' '${DST}'
fi
resolve_digest_ref() {
  local img="\$1" repo="\$2" d
  d=\$("\$CRANE" digest --insecure "\${img}" | tr -d '\\r\\n')
  case "\${d}" in
    *@sha256:*) printf '%s' "\${d}" ;;
    sha256:*) printf '%s@%s' "\${repo}" "\${d}" ;;
    *) printf '%s@%s' "\${repo}" "\${d}" ;;
  esac
}
digest_hex() {
  local d="\$1"
  case "\${d}" in
    *@sha256:*) printf '%s' "\${d#*@sha256:}" ;;
    sha256:*) printf '%s' "\${d#sha256:}" ;;
    *) printf '%s' "\${d}" ;;
  esac
}
sig_ref_for_repo() {
  local repo="\$1" hex="\$2"
  printf '%s:sha256-%s.sig' "\${repo}" "\${hex}"
}
sig_present() {
  local ref="\$1"
  "\$CRANE" manifest --insecure "\${ref}" >/dev/null 2>&1
}
copy_sig_artifact() {
  local src_sig="\$1" dst_sig="\$2"
  if ! sig_present "\${src_sig}"; then
    return 1
  fi
  echo "[cosign-lab] crane copy sig \${src_sig} -> \${dst_sig}"
  "\$CRANE" copy --insecure "\${src_sig}" "\${dst_sig}"
  sig_present "\${dst_sig}"
}
SRC_D=\$(resolve_digest_ref '${SRC}' '${SRC_REPO}')
DST_D=\$(resolve_digest_ref '${DST}' '${DST_REPO}')
HEX=\$(digest_hex "\$SRC_D")
echo "[cosign-lab] SRC_D=\$SRC_D"
echo "[cosign-lab] DST_D=\$DST_D"
echo "[cosign-lab] HEX=\$HEX"
DST_SIG=\$(sig_ref_for_repo '${DST_REPO}' "\$HEX")
if sig_present "\${DST_SIG}"; then
  echo "OK: signature artifact already on \${DST_SIG}"
  exit 0
fi
# Harbor cosign signature tag (digest-based)
SRC_SIG=\$(sig_ref_for_repo '${SRC_REPO}' "\$HEX")
if copy_sig_artifact "\${SRC_SIG}" "\${DST_SIG}"; then
  echo "OK: crane copied digest .sig to nip.io"
  exit 0
fi
# cosign triangulate on IP (HTTP) — exact .sig tag from Jenkins sign step
if [ -x "\$COSIGN" ]; then
  for IMG in '${SRC}' '${SRC_D}'; do
    TRI=\$("\$COSIGN" triangulate --allow-insecure-registry "\${IMG}" 2>/dev/null || "\$COSIGN" triangulate "\${IMG}" 2>/dev/null || true)
    if [ -n "\${TRI}" ] && sig_present "\${TRI}"; then
      DST_TRI=\$(printf '%s' "\${TRI}" | sed "s|^${SRC_REPO}|${DST_REPO}|")
      if copy_sig_artifact "\${TRI}" "\${DST_TRI}"; then
        echo "OK: crane copied triangulated .sig to nip.io"
        exit 0
      fi
    fi
  done
fi
# Tag-based signature (Jenkins also signs :tag on IP)
TAG_SIG='${SRC_REPO}:${IMAGE_TAG}.sig'
DST_TAG_SIG='${DST_REPO}:${IMAGE_TAG}.sig'
if copy_sig_artifact "\${TAG_SIG}" "\${DST_TAG_SIG}"; then
  echo "OK: crane copied tag .sig to nip.io"
  exit 0
fi
echo "ERROR: no .sig on IP registry for ${SRC} (run Jenkins build cosign step first)" >&2
exit 1
SCRIPT
}

run_via_jenkins() {
  local pod
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  echo "==> crane sig copy via ${JENKINS_NS}/${pod}"
  kubectl exec -n "${JENKINS_NS}" "${pod}" -- sh -ce "$(jenkins_cosign_script)"
}

run_k8s_job() {
  local pod job auth_secret
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  job="paas-cosign-nipio-${PROJECT_SLUG}-$(date +%s)"
  auth_secret="paas-harbor-cosign-auth"
  kubectl create namespace "${JOB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry "${auth_secret}" -n "${JOB_NS}" \
    --docker-server="${HARBOR_HOST}:${HARBOR_PORT}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret docker-registry "${auth_secret}-ip" -n "${JOB_NS}" \
    --docker-server="${NODE_IP}:${HARBOR_PORT}" \
    --docker-username="${HARBOR_USER}" \
    --docker-password="${HARBOR_PASS}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "==> crane sig Job ${JOB_NS}/${job}"
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
  kubectl apply -n "${JOB_NS}" -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${JOB_NS}
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        fsGroup: 65532
      containers:
        - name: crane
          image: gcr.io/go-containerregistry/crane:debug
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            allowPrivilegeEscalation: false
          env:
            - name: HOME
              value: /tmp
          command: ["/busybox/sh", "-ce"]
          args:
            - |
              set -e
              CRANE=/ko-app/crane
              \$CRANE auth login '${HARBOR_HOST}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure
              \$CRANE auth login '${NODE_IP}:${HARBOR_PORT}' -u '${HARBOR_USER}' -p '${HARBOR_PASS}' --insecure
              HEX=\$(\$CRANE digest --insecure '${SRC}' | tr -d '\\r\\n' | sed 's/.*@*sha256://')
              SRC_SIG='${SRC_REPO}:sha256-'\${HEX}'.sig'
              DST_SIG='${DST_REPO}:sha256-'\${HEX}'.sig'
              \$CRANE copy --insecure '${SRC}' '${DST}' 2>/dev/null || true
              echo "copy sig \${SRC_SIG} -> \${DST_SIG}"
              \$CRANE copy --insecure "\${SRC_SIG}" "\${DST_SIG}"
              \$CRANE manifest --insecure "\${DST_SIG}" >/dev/null
              echo OK crane sig copy
EOF
  if ! kubectl wait --for=condition=complete "job/${job}" -n "${JOB_NS}" --timeout=180s; then
    kubectl logs "job/${job}" -n "${JOB_NS}" --tail=80 2>/dev/null || true
    kubectl describe job "${job}" -n "${JOB_NS}" 2>/dev/null | tail -25 || true
    kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi
  kubectl logs "job/${job}" -n "${JOB_NS}" --tail=20
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

load_env
bash "${SCRIPT_DIR}/fix-harbor-cosign-realm-lab.sh" 2>/dev/null || true
echo "==> Ensure cosign .sig on ${DST} (from ${SRC})"
if run_via_jenkins; then
  echo "OK: signature on nip.io via Jenkins crane"
  exit 0
fi
echo "WARN: Jenkins crane sig copy failed — trying k8s Job" >&2
if run_k8s_job; then
  echo "OK: signature on nip.io via k8s Job"
  exit 0
fi
echo "ERROR: could not copy cosign signature to ${DST}" >&2
exit 1
