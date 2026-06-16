#!/usr/bin/env bash
set -euo pipefail
PROJECT_SLUG="${1:?usage: ensure-harbor-nipio-cosign-lab.sh <slug> <tag>}"
IMAGE_TAG="${2:?usage: ensure-harbor-nipio-cosign-lab.sh <slug> <tag>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
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

jenkins_remote_script() {
  cat <<'EOS'
set -e
find_crane() {
  local c
  for c in /var/jenkins_home/.jenkins-paas-cache/crane/*/crane /var/jenkins_home/bin/crane; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v crane 2>/dev/null || true
}
find_cosign() {
  local c
  for c in /var/jenkins_home/bin/cosign /var/jenkins_home/cosign-lab/cosign; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v cosign 2>/dev/null || true
}
CRANE=$(find_crane)
COSIGN=$(find_cosign)
KEY='/var/jenkins_home/cosign-lab/cosign.key'
[ -n "$CRANE" ] || { echo "ERROR: missing crane"; exit 1; }
export COSIGN_EXPERIMENTAL=1
"$CRANE" auth login "$NODE_IP:$HARBOR_PORT" -u "$HARBOR_USER" -p "$HARBOR_PASS" --insecure
"$CRANE" auth login "$HARBOR_HOST:$HARBOR_PORT" -u "$HARBOR_USER" -p "$HARBOR_PASS" --insecure || true
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
triangulate_ref() {
  [ -x "$COSIGN" ] || return 1
  "$COSIGN" triangulate --allow-insecure-registry "$1" 2>/dev/null \
    || "$COSIGN" triangulate "$1" 2>/dev/null || true
}
ip_signed() {
  local t
  t=$(triangulate_ref "$SRC_D")
  if [ -n "$t" ] && sig_ok "$t"; then
    printf '%s' "$t"
    return 0
  fi
  t=$(triangulate_ref "$SRC")
  if [ -n "$t" ] && sig_ok "$t"; then
    printf '%s' "$t"
    return 0
  fi
  sig_ok "$SRC_SIG" && { printf '%s' "$SRC_SIG"; return 0; }
  sig_ok "$TAG_SIG" && { printf '%s' "$TAG_SIG"; return 0; }
  if [ -x "$COSIGN" ] && "$COSIGN" tree --allow-insecure-registry "$SRC_D" 2>/dev/null | grep -qi signature; then
    printf '%s' "$SRC_D"
    return 0
  fi
  return 1
}
copy_sig() {
  local s="$1" d="$2"
  sig_ok "$s" || return 1
  echo "[cosign-lab] crane copy sig $s -> $d"
  "$CRANE" copy --insecure "$s" "$d"
  sig_ok "$d"
}
nipio_dst_for_tri() { printf '%s' "$1" | sed "s|^$SRC_REPO|$DST_REPO|"; }
sign_ip_image() {
  [ -x "$COSIGN" ] && [ -f "$KEY" ] || { echo "ERROR: cosign=[$COSIGN] key=[$KEY]"; return 1; }
  export COSIGN_EXPERIMENTAL=1
  echo "$HARBOR_PASS" | "$COSIGN" login "$NODE_IP:$HARBOR_PORT" -u "$HARBOR_USER" --password-stdin --allow-insecure-registry 2>/dev/null || true
  echo "[cosign-lab] cosign sign IP digest $SRC_D"
  set +e
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" "$COSIGN" sign --yes --allow-insecure-registry --key "$KEY" "$SRC_D" 2>&1
  rc1=$?
  echo "[cosign-lab] cosign sign IP tag $SRC (rc digest=$rc1)"
  COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" "$COSIGN" sign --yes --allow-insecure-registry --key "$KEY" "$SRC" 2>&1
  rc2=$?
  set -e
  sleep 3
  TRI=$(ip_signed || true)
  if [ -n "$TRI" ]; then
    echo "[cosign-lab] IP signature ref: $TRI"
    return 0
  fi
  if [ -x "$COSIGN" ] && "$COSIGN" tree --allow-insecure-registry "$SRC_D" 2>/dev/null | grep -qi signature; then
    echo "[cosign-lab] IP signature present (cosign tree on digest)"
    return 0
  fi
  echo "ERROR: cosign sign did not create Harbor signature (rc digest=$rc1 tag=$rc2)" >&2
  return 1
}
SRC_D=$(resolve_digest_ref "$SRC" "$SRC_REPO")
HEX=$(digest_hex "$SRC_D")
SRC_SIG=$(sig_ref "$SRC_REPO" "$HEX")
DST_SIG=$(sig_ref "$DST_REPO" "$HEX")
TAG_SIG="$SRC_REPO:$IMAGE_TAG.sig"
DST_TAG_SIG="$DST_REPO:$IMAGE_TAG.sig"
echo "[cosign-lab] SRC_D=$SRC_D HEX=$HEX"
echo "[cosign-lab] SRC_SIG=$SRC_SIG"
echo "[cosign-lab] DST_SIG=$DST_SIG"
echo "[cosign-lab] harbor tags:" $($CRANE ls --insecure "$SRC_REPO" 2>/dev/null | grep -E "sig|${IMAGE_TAG}" | head -8 | tr '\n' ' ' || true)
if sig_ok "$DST_SIG"; then
  echo "OK: signature already on $DST_SIG"
  exit 0
fi
IP_TRI=$(ip_signed || true)
if [ -z "$IP_TRI" ]; then
  echo "[cosign-lab] no signature on IP — signing now"
  sign_ip_image
  IP_TRI=$(ip_signed)
fi
case "$IP_TRI" in
  *@sha256:*)
    if [ -x "$COSIGN" ] && "$COSIGN" tree --allow-insecure-registry "$DST_REPO@${IP_TRI#*@}" 2>/dev/null | grep -qi signature; then
      echo "OK: cosign signature on nip.io digest (cosign tree)"
      exit 0
    fi
    DST_D="$DST_REPO@${IP_TRI#*@}"
    if copy_sig "$(sig_ref "$SRC_REPO" "$(digest_hex "$IP_TRI")")" "$(sig_ref "$DST_REPO" "$(digest_hex "$IP_TRI")")"; then
      echo "OK: crane copied digest .sig to nip.io"
      exit 0
    fi
    if [ -x "$COSIGN" ] && "$COSIGN" tree --allow-insecure-registry "$SRC_D" 2>/dev/null | grep -qi signature; then
      echo "OK: IP digest signed (nip.io copy skipped; Kyverno Audit / cluster pulls IP ref)"
      exit 0
    fi
    ;;
esac
DST_TRI=$(nipio_dst_for_tri "$IP_TRI")
if copy_sig "$IP_TRI" "$DST_TRI"; then
  echo "OK: crane copied cosign signature to nip.io"
  exit 0
fi
if copy_sig "$SRC_SIG" "$DST_SIG"; then
  echo "OK: crane copied digest .sig to nip.io"
  exit 0
fi
if copy_sig "$TAG_SIG" "$DST_TAG_SIG"; then
  echo "OK: crane copied tag .sig to nip.io"
  exit 0
fi
echo "ERROR: could not copy cosign signature to nip.io for $DST" >&2
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
    COSIGN_PASSWORD="${COSIGN_PASSWORD:-}" \
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
  local pod job key key_secret
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  key="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- cat /var/jenkins_home/cosign-lab/cosign.key 2>/dev/null || true)"
  [[ -n "${key}" ]] || return 1
  key_secret="paas-cosign-signing-key"
  job="paas-cosign-nipio-${PROJECT_SLUG}-$(date +%s)"
  kubectl create namespace "${JOB_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl create secret generic "${key_secret}" -n "${JOB_NS}" \
    --from-literal=cosign.key="${key}" \
    --from-literal=cosign.password="${COSIGN_PASSWORD:-}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  echo "==> cosign sign+copy Job ${JOB_NS}/${job}"
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
      volumes:
        - name: cosign-key
          secret:
            secretName: ${key_secret}
      containers:
        - name: cosign
          image: ghcr.io/sigstore/cosign/cosign:v2.4.1
          securityContext:
            runAsNonRoot: true
            runAsUser: 65532
            allowPrivilegeEscalation: false
          volumeMounts:
            - name: cosign-key
              mountPath: /cosign
              readOnly: true
          env:
            - name: COSIGN_EXPERIMENTAL
              value: "1"
            - name: HOME
              value: /tmp
            - name: COSIGN_PASSWORD
              value: "${COSIGN_PASSWORD:-}"
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
          command: ["/bin/sh", "-ce"]
          args:
            - |
              set -e
              export COSIGN_PRIVATE_KEY="\$(cat /cosign/cosign.key)"
              ARCH=\$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
              wget -q -O /tmp/crane.tgz "https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_Linux_\${ARCH}.tar.gz"
              tar -xzf /tmp/crane.tgz -C /usr/local/bin crane 2>/dev/null || { tar -xzf /tmp/crane.tgz -C /tmp; install /tmp/crane /usr/local/bin/crane; }
              crane auth login ${NODE_IP}:${HARBOR_PORT} -u "\$HARBOR_USER" -p "\$HARBOR_PASS" --insecure
              crane auth login ${HARBOR_HOST}:${HARBOR_PORT} -u "\$HARBOR_USER" -p "\$HARBOR_PASS" --insecure || true
              crane copy --insecure "\$SRC" "\$DST" 2>/dev/null || true
              HEX=\$(crane digest --insecure "\$SRC" | tr -d '\\r\\n' | sed 's/.*@*sha256://')
              SRC_D="\$SRC_REPO@sha256:\${HEX}"
              SRC_SIG="\$SRC_REPO:sha256-\${HEX}.sig"
              DST_SIG="\$DST_REPO:sha256-\${HEX}.sig"
              if ! crane manifest --insecure "\$SRC_SIG" >/dev/null 2>&1; then
                echo "cosign sign IP \$SRC_D"
                cosign sign --yes --allow-insecure-registry --key env://COSIGN_PRIVATE_KEY "\$SRC_D" || true
                cosign sign --yes --allow-insecure-registry --key env://COSIGN_PRIVATE_KEY "\$SRC" || true
              fi
              echo "crane copy \$SRC_SIG -> \$DST_SIG"
              crane copy --insecure "\$SRC_SIG" "\$DST_SIG"
              crane manifest --insecure "\$DST_SIG" >/dev/null
              echo OK crane sig copy
EOF
  if ! kubectl wait --for=condition=complete "job/${job}" -n "${JOB_NS}" --timeout=300s; then
    kubectl logs "job/${job}" -n "${JOB_NS}" --tail=80 2>/dev/null || true
    kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
    return 1
  fi
  kubectl logs "job/${job}" -n "${JOB_NS}" --tail=20
  kubectl delete job "${job}" -n "${JOB_NS}" --ignore-not-found >/dev/null 2>&1 || true
}

verify_nipio_sig() {
  local pod hex dst_sig out
  pod="$(jenkins_pod)"
  [[ -n "${pod}" ]] || return 1
  if ! out="$(kubectl exec -n "${JENKINS_NS}" "${pod}" -- env \
    SRC="${SRC}" DST_REPO="${DST_REPO}" \
    sh -ce "$(cat <<'EOS'
find_crane() {
  local c
  for c in /var/jenkins_home/.jenkins-paas-cache/crane/*/crane /var/jenkins_home/bin/crane; do
    [ -x "$c" ] && { printf '%s' "$c"; return 0; }
  done
  command -v crane 2>/dev/null || true
}
CRANE=$(find_crane)
[ -n "$CRANE" ] || exit 1
HEX=$("$CRANE" digest --insecure "$SRC" | tr -d '\r\n' | sed 's/.*@*sha256://')
DST_SIG="$DST_REPO:sha256-${HEX}.sig"
DST_D="$DST_REPO@sha256:${HEX}"
"$CRANE" manifest --insecure "$DST_SIG" >/dev/null 2>/dev/null && { echo "$DST_SIG"; exit 0; }
COSIGN=$(command -v cosign 2>/dev/null || true)
[ -x /var/jenkins_home/bin/cosign ] && COSIGN=/var/jenkins_home/bin/cosign
if [ -x "$COSIGN" ] && "$COSIGN" tree --allow-insecure-registry "$DST_D" 2>/dev/null | grep -qi signature; then
  echo "$DST_D (cosign tree)"
  exit 0
fi
exit 1
EOS
)" 2>&1)"; then
    echo "${out}" >&2
    return 1
  fi
  echo "verified ${out}"
}

load_env
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
