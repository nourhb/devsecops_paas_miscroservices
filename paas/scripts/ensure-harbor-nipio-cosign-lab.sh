#!/usr/bin/env bash
# Copy cosign .sig artifact IP -> harbor.<nip>.nip.io (Kyverno verifies nip.io ref).
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
  [[ -f "${ENV_FILE}" ]] || return 0
  HARBOR_USER="$(grep -E '^HARBOR_USER=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  HARBOR_PASS="$(grep -E '^HARBOR_PASS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"' | xargs || true)"
  [[ -z "${HARBOR_USER}" ]] && HARBOR_USER="admin"
  [[ -z "${HARBOR_PASS}" ]] && HARBOR_PASS="Harbor12345"
}

jenkins_pod() {
  kubectl get pods -n "${JENKINS_NS}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
    | grep -i jenkins | grep -v Terminating | head -1 || true
}

# Quoted heredoc — host must not expand remote shell variables (set -u false-OK bug).
jenkins_remote_script() {
  cat <<'EOS'
set -e
CRANE=''
for c in /var/jenkins_home/.jenkins-paas-cache/crane/*/crane /var/jenkins_home/bin/crane; do
  [ -x "$c" ] && CRANE="$c" && break
done
[ -n "$CRANE" ] || CRANE=$(command -v crane 2>/dev/null || true)
COSIGN=/var/jenkins_home/bin/cosign
[ -x "$COSIGN" ] || COSIGN=$(command -v cosign 2>/dev/null || true)
[ -n "$CRANE" ] || { echo "ERROR: missing crane"; exit 1; }
export COSIGN_EXPERIMENTAL=1
"$CRANE" auth login "$HARBOR_HOST:$HARBOR_PORT" -u "$HARBOR_USER" -p "$HARBOR_PASS" --insecure \
  || "$CRANE" auth login "$NODE_IP:$HARBOR_PORT" -u "$HARBOR_USER" -p "$HARBOR_PASS" --insecure
SRC="$NODE_IP:$HARBOR_PORT/paas/$PROJECT_SLUG:$IMAGE_TAG"
DST="$HARBOR_HOST:$HARBOR_PORT/paas/$PROJECT_SLUG:$IMAGE_TAG"
SRC_REPO="$NODE_IP:$HARBOR_PORT/paas/$PROJECT_SLUG"
DST_REPO="$HARBOR_HOST:$HARBOR_PORT/paas/$PROJECT_SLUG"
if ! "$CRANE" digest --insecure "$DST" >/dev/null 2>&1; then
  echo "[cosign-lab] crane copy image $SRC -> $DST"
  "$CRANE" copy --insecure "$SRC" "$DST" || "$CRANE" tag --insecure "$SRC" "$DST"
fi
resolve_digest_ref() {
  local img="$1" repo="$2" d
  d=$("$CRANE" digest --insecure "$img" | tr -d '\r\n')
  case "$d" in
    *@sha256:*) printf '%s' "$d" ;;
    sha256:*) printf '%s@%s' "$repo" "$d" ;;
    *) printf '%s@%s' "$repo" "$d" ;;
  esac
}
digest_hex() {
  local d="$1"
  case "$d" in
    *@sha256:*) printf '%s' "${d#*@sha256:}" ;;
    sha256:*) printf '%s' "${d#sha256:}" ;;
    *) printf '%s' "$d" ;;
  esac
}
sig_ref() { printf '%s:sha256-%s.sig' "$1" "$2"; }
sig_ok() { "$CRANE" manifest --insecure "$1" >/dev/null 2>&1; }
copy_sig() {
  local s="$1" d="$2"
  sig_ok "$s" || return 1
  echo "[cosign-lab] crane copy sig $s -> $d"
  "$CRANE" copy --insecure "$s" "$d"
  sig_ok "$d"
}
SRC_D=$(resolve_digest_ref "$SRC" "$SRC_REPO")
HEX=$(digest_hex "$SRC_D")
DST_SIG=$(sig_ref "$DST_REPO" "$HEX")
echo "[cosign-lab] SRC_D=$SRC_D HEX=$HEX"
echo "[cosign-lab] DST_SIG=$DST_SIG"
if sig_ok "$DST_SIG"; then
  echo "OK: signature already on $DST_SIG"
  exit 0
fi
SRC_SIG=$(sig_ref "$SRC_REPO" "$HEX")
if copy_sig "$SRC_SIG" "$DST_SIG"; then
  echo "OK: crane copied digest .sig to nip.io"
  exit 0
fi
if [ -x "$COSIGN" ]; then
  for IMG in "$SRC" "$SRC_D"; do
    TRI=$("$COSIGN" triangulate --allow-insecure-registry "$IMG" 2>/dev/null \
      || "$COSIGN" triangulate "$IMG" 2>/dev/null || true)
    if [ -n "$TRI" ] && sig_ok "$TRI"; then
      DST_TRI=$(printf '%s' "$TRI" | sed "s|^$SRC_REPO|$DST_REPO|")
      if copy_sig "$TRI" "$DST_TRI"; then
        echo "OK: crane copied triangulated .sig to nip.io"
        exit 0
      fi
    fi
  done
fi
TAG_SIG="$SRC_REPO:$IMAGE_TAG.sig"
DST_TAG_SIG="$DST_REPO:$IMAGE_TAG.sig"
if copy_sig "$TAG_SIG" "$DST_TAG_SIG"; then
  echo "OK: crane copied tag .sig to nip.io"
  exit 0
fi
echo "ERROR: no .sig on IP for $SRC — Jenkins cosign step missing?" >&2
exit 1
EOS
}

run_via_jenkins() {
  local pod out rc
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  echo "==> crane sig copy via ${JENKINS_NS}/${pod}"
  if ! out="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- env \
    NODE_IP="${NODE_IP}" \
    HARBOR_HOST="${HARBOR_HOST}" \
    HARBOR_PORT="${HARBOR_PORT}" \
    HARBOR_USER="${HARBOR_USER}" \
    HARBOR_PASS="${HARBOR_PASS}" \
    PROJECT_SLUG="${PROJECT_SLUG}" \
    IMAGE_TAG="${IMAGE_TAG}" \
    sh -ce "$(jenkins_remote_script)" 2>&1)"; then
    echo "${out}" >&2
    return 1
  fi
  echo "${out}"
  echo "${out}" | grep -qE '^OK:' || return 1
}

run_k8s_job() {
  local pod job
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  job="paas-cosign-nipio-${PROJECT_SLUG}-$(date +%s)"
  kubectl create namespace "${JOB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
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
            - name: SRC
              value: "${SRC}"
            - name: DST
              value: "${DST}"
            - name: SRC_REPO
              value: "${SRC_REPO}"
            - name: DST_REPO
              value: "${DST_REPO}"
            - name: HARBOR_USER
              value: "${HARBOR_USER}"
            - name: HARBOR_PASS
              value: "${HARBOR_PASS}"
          command: ["/busybox/sh", "-ce"]
          args:
            - |
              set -e
              C=/ko-app/crane
              \$C auth login ${HARBOR_HOST}:${HARBOR_PORT} -u "\$HARBOR_USER" -p "\$HARBOR_PASS" --insecure
              \$C auth login ${NODE_IP}:${HARBOR_PORT} -u "\$HARBOR_USER" -p "\$HARBOR_PASS" --insecure
              \$C copy --insecure "\$SRC" "\$DST" 2>/dev/null || true
              HEX=\$(\$C digest --insecure "\$SRC" | tr -d '\\r\\n' | sed 's/.*@*sha256://')
              SS="\$SRC_REPO:sha256-\${HEX}.sig"
              DS="\$DST_REPO:sha256-\${HEX}.sig"
              echo "copy \$SS -> \$DS"
              \$C copy --insecure "\$SS" "\$DS"
              \$C manifest --insecure "\$DS" >/dev/null
              echo OK crane sig copy
EOF
  if ! kubectl wait --for=condition=complete "job/${job}" -n "${JOB_NS}" --timeout=180s; then
    kubectl logs "job/${job}" -n "${JOB_NS}" --tail=80 2>/dev/null || true
    kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi
  kubectl logs "job/${job}" -n "${JOB_NS}" --tail=20
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

verify_nipio_sig() {
  local pod hex dst_sig
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  hex="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- env \
    SRC="${SRC}" \
    sh -ce 'crane=$(command -v crane 2>/dev/null || echo /var/jenkins_home/bin/crane); \
      $crane digest --insecure "$SRC" 2>/dev/null | tr -d "\r\n" | sed "s/.*@*sha256://"' 2>/dev/null || true)"
  [[ -n "${hex}" ]] || return 1
  dst_sig="${DST_REPO}:sha256-${hex}.sig"
  kubectl exec -n "${JENKINS_NS}" "${pod}" -- sh -ce \
    "crane=\$(command -v crane 2>/dev/null || echo /var/jenkins_home/bin/crane); \
     \$crane manifest --insecure '${dst_sig}' >/dev/null" 2>/dev/null
}

load_env
bash "${SCRIPT_DIR}/fix-harbor-cosign-realm-lab.sh" 2>/dev/null || true
echo "==> Ensure cosign .sig on ${DST} (from ${SRC})"
if run_via_jenkins && verify_nipio_sig; then
  echo "OK: verified cosign .sig on nip.io"
  exit 0
fi
echo "WARN: Jenkins crane sig copy failed — trying k8s Job" >&2
if run_k8s_job && verify_nipio_sig; then
  echo "OK: verified cosign .sig on nip.io (k8s Job)"
  exit 0
fi
echo "ERROR: cosign signature not on ${DST}" >&2
echo "  Check IP sig: kubectl exec -n ${JENKINS_NS} \$(kubectl get pods -n ${JENKINS_NS} -o name | grep jenkins | head -1) -- crane manifest --insecure ${SRC_REPO}:sha256-<hex>.sig" >&2
exit 1
