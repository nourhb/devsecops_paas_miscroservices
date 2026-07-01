// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626
def dockerlessImagePush(String craneBin, String imageRef, String dockerfilePath) {
  def appRoot = detectAppRoot()
  println "[image] PAAS app root for build layer: ${appRoot}"
  materializeProjectBuildEnv(appRoot)
  patchNextBuildEnvIntoConfig(appRoot)
  def artifactImageRef = normalizeOciImageReference(imageRef)
  imageRef = resolveHarborPushImageRef(artifactImageRef)
  if (imageRef != artifactImageRef) {
    println "[image] Harbor registry host coerced for push: ${artifactImageRef} → ${imageRef}"
  }
  artifactImageRef = imageRef
  def registry = normalizeRegistryHost(registryHostFor(imageRef))
  def harborRegistry = params.HARBOR_REGISTRY?.trim() ?: env.HARBOR_REGISTRY ?: ""
  def harborHost = normalizeRegistryHost(harborRegistry)
  if (!harborHost && registry.contains('.nip.io')) {
    harborHost = registry
  }
  def pushHost = registry
  def craneInsecure = "--insecure"
  def dockerhubUser = params.DOCKERHUB_USERNAME?.trim() ?: env.DOCKERHUB_USERNAME ?: ""
  def dockerhubToken = params.DOCKERHUB_TOKEN?.trim() ?: env.DOCKERHUB_TOKEN ?: ""
  def harborUser = params.HARBOR_USERNAME?.trim() ?: env.HARBOR_USERNAME ?: ""
  def harborPassword = params.HARBOR_PASSWORD?.trim() ?: env.HARBOR_PASSWORD ?: ""

  if (registry == "index.docker.io") {
    if (!dockerhubUser || !dockerhubToken) {
      error("Docker Hub credentials are required for dockerless image push.")
    }
    withEnv(["CRANE_BIN=${craneBin}", "REGISTRY=${registry}", "REGISTRY_USER=${dockerhubUser}", "REGISTRY_PASS=${dockerhubToken}", "IMAGE_REF=${imageRef}"]) {
      sh '''
        set -eu
        "$CRANE_BIN" auth login "$REGISTRY" -u "$REGISTRY_USER" -p "$REGISTRY_PASS"
      '''
    }
  } else if (harborHost && (registry == harborHost || pushHost == harborHost || registry.contains('.nip.io'))) {
    if (!harborUser || !harborPassword) {
      error("Harbor credentials are required for dockerless image push.")
    }
    withEnv(["CRANE_BIN=${craneBin}", "REGISTRY=${registry}", "REGISTRY_IP=${harborIpRegistryHostFromNipio(registry)}", "REGISTRY_USER=${harborUser}", "REGISTRY_PASS=${harborPassword}", "IMAGE_REF=${imageRef}"]) {
      sh '''
        set -eu
        echo "[image] probing Harbor http://${REGISTRY}/v2/ before login…"
        if command -v getent >/dev/null 2>&1; then
          getent hosts "${REGISTRY%%:*}" 2>/dev/null || echo "[image] WARN: DNS lookup failed for ${REGISTRY%%:*}"
        fi
        _harbor_ok=0
        for _try in 1 2 3 4 5 6; do
          _hc="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 25 "http://${REGISTRY}/v2/" 2>/dev/null || echo 000)"
          if [ "${_hc}" = "200" ] || [ "${_hc}" = "401" ]; then
            echo "[image] Harbor /v2/ OK (HTTP ${_hc})"
            _harbor_ok=1
            break
          fi
          echo "[image] WARN: Harbor /v2/ HTTP ${_hc} (attempt ${_try}/6) — 502 = run: bash paas/scripts/lab.sh harbor"
          sleep 20
        done
        if [ "${_harbor_ok}" != "1" ]; then
          echo "[image] ERROR: Harbor registry not reachable at http://${REGISTRY}/v2/ — fix Harbor before crane push"
          exit 1
        fi
        for _reg in "${REGISTRY_IP}" "${REGISTRY}"; do
          [ -z "${_reg}" ] && continue
          echo "[image] crane auth login ${_reg} …"
          export DOCKER_CONFIG="${JENKINS_HOME:-/var/jenkins_home}/.docker-paas-crane"
          mkdir -p "${DOCKER_CONFIG}"
          printf '%s' "${REGISTRY_PASS}" | "$CRANE_BIN" auth login "${_reg}" -u "${REGISTRY_USER}" --password-stdin --insecure
        done
        echo "[image] crane dual auth OK (IP ${REGISTRY_IP} + nip.io ${REGISTRY})"
      '''
    }
  }

  def dfPath = (dockerfilePath ?: 'Dockerfile').trim()
  def imageStack = detectProjectFramework(appRoot)
  def runtimeStack = resolveCraneRuntimeStack(appRoot, dfPath)
  println "[image] detected framework=${imageStack} crane runtime=${runtimeStack} (app root: ${appRoot}, dockerfile: ${dfPath})"

  if (runtimeStack == 'python') {
    dockerlessPythonCranePush(craneBin, imageRef, artifactImageRef, craneInsecure, appRoot)
    return
  }
  if (fileExists("${appRoot}/package.json")) {
    ensureNodeTool(resolveNodeVersion(appRoot))
  }
  if (runtimeStack == 'nginx') {
    dockerlessNginxCranePush(craneBin, imageRef, artifactImageRef, craneInsecure, appRoot, imageStack)
    return
  }

  dockerlessImagePushCraneNode6a(appRoot)
  dockerlessImagePushCraneNode6b(appRoot, imageStack)
  verifyNextPublicEnvInBuild(appRoot)
  dockerlessImagePushCraneNode6c(craneBin, imageRef, artifactImageRef, craneInsecure, appRoot)

}

def cosignSignImageShellSnippet() {
  return '''
            set +e
            export COSIGN_PASSWORD="${COSIGN_PASSWORD:-}"
            export COSIGN_EXPERIMENTAL=1
            harbor_nipio_to_ip_ref() {
              local ref="$1"
              case "$ref" in
                harbor.*.nip.io:*/*|harbor.*.nip.io/*)
                  local host="${ref%%/*}"
                  local rest="${ref#*/}"
                  local nip_host port ip
                  nip_host="${host%%:*}"
                  port="${host#*:}"
                  if [ "${port}" = "${nip_host}" ]; then
                    port=""
                  fi
                  ip="$(printf '%s' "${nip_host}" | sed -nE 's/^harbor\\.([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)\\.nip\\.io$/\\1/p')"
                  if [ -z "${ip}" ]; then
                    return 1
                  fi
                  if [ -n "${port}" ]; then
                    printf '%s/%s' "${ip}:${port}" "${rest}"
                  else
                    printf '%s/%s' "${ip}" "${rest}"
                  fi
                  return 0
                  ;;
              esac
              return 1
            }
            sig_ok() {
              local ref="$1" crane="${CRANE_BIN:-}"
              [ -n "${crane}" ] && [ -x "${crane}" ] || crane="$(command -v crane 2>/dev/null || true)"
              [ -n "${crane}" ] && [ -x "${crane}" ] || return 1
              "${crane}" manifest --insecure "${ref}" >/dev/null 2>&1
            }
            copy_sig_ref() {
              local src="$1" dst="$2" crane="${CRANE_BIN:-}"
              [ -n "${crane}" ] && [ -x "${crane}" ] || crane="$(command -v crane 2>/dev/null || true)"
              [ -n "${crane}" ] && [ -x "${crane}" ] || return 1
              sig_ok "${src}" || return 1
              echo "[cosign] crane copy signature ${src} -> ${dst}"
              "${crane}" copy --insecure "${src}" "${dst}" >/dev/null 2>&1 && sig_ok "${dst}"
            }
            nipio_dst_for_tri() {
              local tri="$1" nip_ref="$2" ip_ref="$3"
              local nip_repo="${nip_ref%%@*}"
              nip_repo="${nip_repo%:*}"
              local ip_repo="${ip_ref%%@*}"
              ip_repo="${ip_repo%:*}"
              printf '%s' "${tri}" | sed "s|^${ip_repo}|${nip_repo}|"
            }
            sign_nipio_via_ip() {
              local nip_ref="$1"
              local ip_ref
              ip_ref="$(harbor_nipio_to_ip_ref "${nip_ref}")" || return 1
              local crane="${CRANE_BIN:-}"
              [ -n "${crane}" ] && [ -x "${crane}" ] || crane="$(command -v crane 2>/dev/null || true)"
              [ -n "${crane}" ] && [ -x "${crane}" ] || {
                echo "[cosign] WARN: nip.io sign needs IP fallback but crane missing"
                return 1
              }
              echo "[cosign] Harbor HTTP nip.io — sign via IP ref ${ip_ref} (no full-image crane copy)"
              if ! "${crane}" digest --insecure "${ip_ref}" >/dev/null 2>&1; then
                echo "[cosign] WARN: IP manifest missing — run ensure-harbor-nipio-cosign-lab.sh after build"
              fi
              local ip_digest nip_repo ip_repo
              ip_digest="$(resolve_digest_ref "${ip_ref}" || true)"
              nip_repo="${nip_ref%%@*}"
              nip_repo="${nip_repo%:*}"
              ip_repo="${ip_ref%%@*}"
              ip_repo="${ip_repo%:*}"
              if [ -n "${ip_digest}" ]; then
                sign_img "${ip_digest}" || true
              fi
              sign_img "${ip_ref}" || true
              local tri dst_tri
              tri="$("${COSIGN_EXE}" triangulate --allow-insecure-registry "${ip_digest:-${ip_ref}}" 2>/dev/null || true)"
              if [ -n "${tri}" ]; then
                dst_tri="$(nipio_dst_for_tri "${tri}" "${nip_ref}" "${ip_ref}")"
                if copy_sig_ref "${tri}" "${dst_tri}"; then
                  echo "[cosign] OK: signature copied to nip.io ${dst_tri}"
                  return 0
                fi
              fi
              local hex="${ip_digest#*@sha256:}"
              hex="${hex#sha256:}"
              if [ -n "${hex}" ]; then
                if copy_sig_ref "${ip_repo}:sha256-${hex}.sig" "${nip_repo}:sha256-${hex}.sig"; then
                  echo "[cosign] OK: digest .sig copied to nip.io"
                  return 0
                fi
              fi
              return 1
            }
            sign_img() {
              local ref="$1"
              local out rc attempt
              local ip_ref
              ip_ref="$(harbor_nipio_to_ip_ref "${ref}" 2>/dev/null || true)"
              if [ -n "${ip_ref}" ]; then
                ref="${ip_ref}"
              fi
              for attempt in 1 2; do
                if command -v timeout >/dev/null 2>&1; then
                  out="$(timeout 120 "${COSIGN_EXE}" sign --yes ${INSEC} --key "${COSIGN_KEY}" "${ref}" 2>&1)"
                elif [ -n "${INSEC}" ]; then
                  out="$("${COSIGN_EXE}" sign --yes ${INSEC} --key "${COSIGN_KEY}" "${ref}" 2>&1)"
                else
                  out="$("${COSIGN_EXE}" sign --yes --key "${COSIGN_KEY}" "${ref}" 2>&1)"
                fi
                rc=$?
                if [ "${rc}" -eq 0 ]; then
                  return 0
                fi
                if echo "${out}" | grep -qE 'createLogEntryConflict|already exists in the transparency log'; then
                  echo "[cosign] WARN: ${ref} already signed (rekor 409) — OK"
                  return 0
                fi
                if echo "${out}" | grep -qE 'connection refused|ECONNREFUSED|timed out|HTTP response to HTTPS|server gave HTTP'; then
                  echo "${out}"
                  if [ "${attempt}" -lt 2 ]; then
                    echo "[cosign] WARN: sign retry (${attempt}/2) in 5s…"
                    sleep 5
                    continue
                  fi
                  echo "[cosign] WARN: could not sign ${ref} — image push OK, deploy continues"
                  return 0
                fi
                echo "${out}"
                return "${rc}"
              done
              return 0
            }
            resolve_digest_ref() {
              local img="$1"
              local d=""
              if [ -f paas-artifacts/image-digest-ref.txt ]; then
                d="$(tr -d '\\r\\n' < paas-artifacts/image-digest-ref.txt)"
                d="$(harbor_nipio_to_ip_ref "${d}" 2>/dev/null || printf '%s' "${d}")"
              fi
              if [ -z "${d}" ] && [ -n "${CRANE_BIN:-}" ] && [ -x "${CRANE_BIN}" ]; then
                d="$("${CRANE_BIN}" digest "${img}" 2>/dev/null | tr -d '\\r\\n' || true)"
              elif [ -z "${d}" ] && command -v crane >/dev/null 2>&1; then
                d="$(crane digest "${img}" 2>/dev/null | tr -d '\\r\\n' || true)"
              fi
              if printf '%s' "${d}" | grep -q '@sha256:'; then
                printf '%s' "${d}"
                return 0
              fi
              if printf '%s' "${d}" | grep -qE '^sha256:[a-f0-9]{64}\$'; then
                local repo="${img%%@*}"
                repo="${repo%:*}"
                printf '%s@%s' "${repo}" "${d}"
                return 0
              fi
              # Harbor cosign triangulate: repo:sha256-<hex>.sig (not @sha256: — still signable once normalized)
              local tri=""
              tri="$("${COSIGN_EXE}" triangulate "${img}" 2>/dev/null || true)"
              if printf '%s' "${tri}" | grep -qE ':sha256-[a-f0-9]{64}(\\.sig)?\$'; then
                local repo="${tri%%:sha256-*}"
                local hex="${tri#*:sha256-}"
                hex="${hex%.sig}"
                printf '%s@sha256:%s' "${repo}" "${hex}"
                return 0
              fi
              return 1
            }
            COSIGN_KEY="${COSIGN_KEY_FILE:-${LAB_KEY:-paas-cosign-private.key}}"
            LAB_SIGN_REF="$(harbor_nipio_to_ip_ref "${COSIGN_IMG}" 2>/dev/null || printf '%s' "${COSIGN_IMG}")"
            if [ "${LAB_SIGN_REF}" != "${COSIGN_IMG}" ]; then
              echo "[cosign] lab Harbor HTTP: sign IP ref ${LAB_SIGN_REF} (artifact stays ${COSIGN_IMG})"
            fi
            DIGEST="$(resolve_digest_ref "${LAB_SIGN_REF}" || true)"
            if [ -n "${DIGEST}" ]; then
              echo "[cosign] signing digest ${DIGEST}"
              echo "PAAS_COSIGN_DIGEST=${DIGEST}"
              sign_img "${DIGEST}" || true
              mkdir -p paas-artifacts
              echo "PAAS_COSIGN_DIGEST=${DIGEST}" >> paas-artifacts/cosign-meta.txt
            else
              echo "[cosign] signing tag ${LAB_SIGN_REF}"
              sign_img "${LAB_SIGN_REF}" || true
            fi
            exit 0
          '''
}

