  env.HARBOR_REGISTRY = coerceHarborHostForCosign((params.HARBOR_REGISTRY?.trim() ?: env.HARBOR_REGISTRY ?: "").trim())
  env.HARBOR_FORCE_NODEPORT_PUSH = (params.HARBOR_FORCE_NODEPORT_PUSH?.trim() ?: env.HARBOR_FORCE_NODEPORT_PUSH ?: 'true').trim()
  if (harborForceNodePortPush()) {
    env.HARBOR_REGISTRY_PUSH = ""
  } else {
    env.HARBOR_REGISTRY_PUSH = (params.HARBOR_REGISTRY_PUSH?.trim() ?: env.HARBOR_REGISTRY_PUSH ?: "").trim()
  }
  env.HARBOR_REGISTRY_NGINX_CLUSTER = (env.HARBOR_REGISTRY_NGINX_CLUSTER ?: "").trim()
  env.HARBOR_REGISTRY_CLUSTER = (env.HARBOR_REGISTRY_CLUSTER ?: "").trim()
  env.HARBOR_USERNAME = (params.HARBOR_USERNAME?.trim() ?: env.HARBOR_USERNAME ?: "").trim()
  env.HARBOR_PASSWORD = (params.HARBOR_PASSWORD?.trim() ?: env.HARBOR_PASSWORD ?: "").trim()
  env.DOCKERHUB_USERNAME = (params.DOCKERHUB_USERNAME?.trim() ?: env.DOCKERHUB_USERNAME ?: "").trim()
  env.DOCKERHUB_TOKEN = (params.DOCKERHUB_TOKEN?.trim() ?: env.DOCKERHUB_TOKEN ?: "").trim()
  env.SONAR_HOST_URL = (params.SONAR_HOST_URL?.trim() ?: env.SONAR_HOST_URL ?: "").trim()
  env.SONAR_TOKEN = (params.SONAR_TOKEN?.trim() ?: env.SONAR_TOKEN ?: "").trim()
  env.NVD_API_KEY = (params.NVD_API_KEY?.trim() ?: env.NVD_API_KEY ?: "").trim()
  env.JENKINS_DEPENDENCY_TRACK_BASE_URL = (params.JENKINS_DEPENDENCY_TRACK_BASE_URL?.trim() ?: env.JENKINS_DEPENDENCY_TRACK_BASE_URL ?: "").trim()
  env.DEPENDENCY_TRACK_BASE_URL = (params.DEPENDENCY_TRACK_BASE_URL?.trim() ?: env.DEPENDENCY_TRACK_BASE_URL ?: "").trim()
  env.DEPENDENCY_TRACK_API_KEY = (params.DEPENDENCY_TRACK_API_KEY?.trim() ?: env.DEPENDENCY_TRACK_API_KEY ?: "").trim()
  env.ARTIFACTORY_URL = (params.ARTIFACTORY_URL?.trim() ?: env.ARTIFACTORY_URL ?: "").trim()
  env.ARTIFACTORY_REPOSITORY = (params.ARTIFACTORY_REPOSITORY?.trim() ?: env.ARTIFACTORY_REPOSITORY ?: "libs-release-local").trim()
  env.ARTIFACTORY_USERNAME = (params.ARTIFACTORY_USERNAME?.trim() ?: env.ARTIFACTORY_USERNAME ?: "").trim()
  env.ARTIFACTORY_PASSWORD = (params.ARTIFACTORY_PASSWORD?.trim() ?: env.ARTIFACTORY_PASSWORD ?: "").trim()
  env.ARTIFACTORY_ACCESS_TOKEN = (params.ARTIFACTORY_ACCESS_TOKEN?.trim() ?: env.ARTIFACTORY_ACCESS_TOKEN ?: "").trim()
  def cosignPem = normalizeCosignPrivateKeyPem(params.COSIGN_PRIVATE_KEY?.trim() ?: env.COSIGN_PRIVATE_KEY ?: "")
  env.COSIGN_PRIVATE_KEY = cosignPem
  env.COSIGN_PASSWORD = (params.COSIGN_PASSWORD?.trim() ?: env.COSIGN_PASSWORD ?: "")
  env.COSIGN_ALLOW_INSECURE_REGISTRY = (params.COSIGN_ALLOW_INSECURE_REGISTRY?.trim() ?: env.COSIGN_ALLOW_INSECURE_REGISTRY ?: "").trim()
  env.HELM_OCI_PROJECT = (params.HELM_OCI_PROJECT?.trim() ?: env.HELM_OCI_PROJECT ?: "paas").trim()
  env.HELM_OCI_INSECURE = (params.HELM_OCI_INSECURE?.trim() ?: env.HELM_OCI_INSECURE ?: "").trim()
  env.HELM_OCI_PLAIN_HTTP = (params.HELM_OCI_PLAIN_HTTP?.trim() ?: env.HELM_OCI_PLAIN_HTTP ?: "").trim()
  env.ZAP_TARGET_URL = (params.ZAP_TARGET_URL?.trim() ?: env.ZAP_TARGET_URL ?: "").trim()
  env.BUILD_PACKAGE_PROXY_URL = (params.BUILD_PACKAGE_PROXY_URL?.trim() ?: env.BUILD_PACKAGE_PROXY_URL ?: "").trim()
  env.NPM_CONFIG_REGISTRY = (params.NPM_CONFIG_REGISTRY?.trim() ?: env.NPM_CONFIG_REGISTRY ?: "").trim()
  env.JENKINS_PAAS_NODE_CACHE = (params.JENKINS_PAAS_NODE_CACHE?.trim() ?: env.JENKINS_PAAS_NODE_CACHE ?: "").trim()
  env.JENKINS_PAAS_NPM_CACHE = (params.JENKINS_PAAS_NPM_CACHE?.trim() ?: env.JENKINS_PAAS_NPM_CACHE ?: "").trim()
  env.JENKINS_SH_KEEPALIVE = (params.JENKINS_SH_KEEPALIVE?.trim() ?: env.JENKINS_SH_KEEPALIVE ?: "true").trim()
  env.JENKINS_SH_KEEPALIVE_SEC = (params.JENKINS_SH_KEEPALIVE_SEC?.trim() ?: env.JENKINS_SH_KEEPALIVE_SEC ?: "20").trim()
  env.JENKINS_NEXT_BUILD_WEBPACK = (params.JENKINS_NEXT_BUILD_WEBPACK?.trim() ?: env.JENKINS_NEXT_BUILD_WEBPACK ?: "").trim()
  env.JENKINS_NEXT_PERSIST_CACHE = (params.JENKINS_NEXT_PERSIST_CACHE?.trim() ?: env.JENKINS_NEXT_PERSIST_CACHE ?: "").trim()
  env.JENKINS_NEXT_BUILD_HEARTBEAT = (params.JENKINS_NEXT_BUILD_HEARTBEAT?.trim() ?: env.JENKINS_NEXT_BUILD_HEARTBEAT ?: "true").trim()
  env.JENKINS_NEXT_BUILD_HEARTBEAT_SEC = (params.JENKINS_NEXT_BUILD_HEARTBEAT_SEC?.trim() ?: env.JENKINS_NEXT_BUILD_HEARTBEAT_SEC ?: "45").trim()
  env.JENKINS_NPM_PRUNE_BEFORE_CRANE = (params.JENKINS_NPM_PRUNE_BEFORE_CRANE?.trim() ?: env.JENKINS_NPM_PRUNE_BEFORE_CRANE ?: "true").trim()
  env.JENKINS_CRANE_STANDALONE_LAYER = (params.JENKINS_CRANE_STANDALONE_LAYER?.trim() ?: env.JENKINS_CRANE_STANDALONE_LAYER ?: "auto").trim()
  env.PROJECT_ID = projectId
  env.PROJECT_BUILD_ENV_B64 = (params.PROJECT_BUILD_ENV_B64 ?: env.PROJECT_BUILD_ENV_B64 ?: "").trim()
  def paasFastPipeline = false
  def fastParam = "${params.JENKINS_PAAS_FAST_PIPELINE ?: ''}".trim()
  env.JENKINS_PAAS_FAST_PIPELINE = "false"
  println "[paas] JENKINS_PAAS_FAST_PIPELINE param=${fastParam} effective=false (security steps always run)"
  if (fastParam.equalsIgnoreCase('true')) {
    println "[paas] WARN: JENKINS_PAAS_FAST_PIPELINE=true was requested but ignored — run bash paas/scripts/lab.sh jenkins if job default is stale"
  }
  if (env.PROJECT_BUILD_ENV_B64?.trim()) {
    println "[env] PROJECT_BUILD_ENV_B64 length=${env.PROJECT_BUILD_ENV_B64.trim().length()} (Application environment + public URL)"
  } else {
    paasStepWarn(1, 'build-env', 'No PROJECT_BUILD_ENV_B64 from PaaS — save Application environment in Edit project and redeploy frontend if needed')
  }
  if (paasFastPipeline) {
    env.JENKINS_SKIP_NEXT_BUILD = "true"
    println "[paas] JENKINS_PAAS_FAST_PIPELINE=true — skipping Steps 4–5 (SCA/SAST), Step 8 (Artifactory bundle), Step 10 (ZAP). Next.js production build still runs before crane tar when using dockerless push (Dockerfile is not executed)."
  }

  def cranePushTimeoutMin = 240
  try {
    def rawTp = (params.JENKINS_CRANE_PUSH_TIMEOUT_MIN?.trim() ?: env.JENKINS_CRANE_PUSH_TIMEOUT_MIN ?: "").trim()
    if (rawTp) cranePushTimeoutMin = Integer.parseInt(rawTp)
  } catch (Exception ignored) {
    cranePushTimeoutMin = 240
  }

  println "[paas-jenkinsfile] marker=steps-1-2-3-4-5-6-7-8-9-10-11-12-202602 (re-sync job from PaaS if console still shows [step1] merged checkout)."
  println "[paas-jenkinsfile] marker=steps-1-2-3-4-5-202602"
  println "[paas-jenkinsfile] marker=crane-next16-202605-j48300-split (node{} built-in; Step 6a/6b/6c; foreground cmd JENKINS-48300)"
  println "[paas-jenkinsfile] marker=crane-mutate-cmd-20260531 (start-paas.sh in layer; no nested quotes in --cmd)"
  println "[paas-jenkinsfile] marker=security-warn-sca-sonar-20260531 (PAAS_STEP_WARN on failed SCA/Sonar; cyclonedx --package-lock-only)"
  println "[paas-jenkinsfile] marker=monorepo-app-root-20260531 (Step 3/6 mutate use detectAppRoot e.g. server/)"
  println "[paas-jenkinsfile] marker=next-config-build-env-20260531 (patch next.config env + force fresh .next when PROJECT_BUILD_ENV_B64 set)"
  println "[paas-jenkinsfile] marker=env-decode-node-20260601 (materialize .env via Node — avoids Jenkins decodeBase64 sandbox)"
  println "[paas-jenkinsfile] marker=env-safe-dotenv-loader-20260601 (Node loads .env — fixes EMAIL_PASS spaces; no . ./.env)"
  println "[paas-jenkinsfile] marker=cosign-sandbox-sh-20260531 standalone-patch-20260531 node-after-ensure-20260531"
  println "[paas-jenkinsfile] marker=cosign-digest-crane-bin-20260602 (CRANE_BIN + PAAS_IMAGE_DIGEST; Harbor triangulate → @sha256:)"
  println '[paas-jenkinsfile] marker=cosign-groovy-dollar-escape-20260603'
  println '[paas-jenkinsfile] marker=crane-imageref-gstring-20260603 (no single-quoted \\${imageRef} in """ blocks)'
  println '[paas-jenkinsfile] marker=harbor-nodeport-push-20260605 (no NGINX_CLUSTER fallback; HARBOR_FORCE_NODEPORT_PUSH default true)'
  println '[paas-jenkinsfile] marker=multi-framework-20260611 (embed-sync; Node16 legacy Angular defer Step6; python/nginx crane; python base 3.12-slim)'
  println '[paas-jenkinsfile] marker=web-spa-static-20260529 (all Angular + vite/spa → nginx:80; defer build to Step 6)'
  println '[paas-jenkinsfile] marker=cosign-lenient-20260610 (409 rekor + Harbor blip → WARN not FAIL)'
  println '[paas-jenkinsfile] marker=cosign-nipio-ip-fallback-20260615 (HTTP Harbor: sign IP + crane copy .sig to nip.io)'
  println '[paas-jenkinsfile] marker=cosign-no-tlog-upload-flag-20260615 (new cosign rejects --tlog-upload=false with signing-config)'
  println '[paas-jenkinsfile] marker=cosign-ip-first-timeout-20260615 (skip nip.io HTTPS + no crane image copy; timeout 120s)'
  println '[paas-jenkinsfile] marker=paas-build-complete-cluster-pull-20260615 (PAAS_BUILD_COMPLETE image=IP for kubelet pull)'
  println '[paas-jenkinsfile] marker=nginx-conf-writefile-20260611 (writeFile default.conf — no $uri in GString sh)'
  println '[paas-jenkinsfile] marker=verify-nextpublic-nextjs-only-20260611 (skip .next check for Express/API)'
  println '[paas-jenkinsfile] marker=sca-cyclonedx-node20-20260611 (cyclonedx-npm needs Node 18+; SCA uses portable Node 20)'
  println '[paas-jenkinsfile] marker=sca-npm-install-full-20260611 (full npm install before cyclonedx when no lockfile — not package-lock-only)'
  println '[paas-jenkinsfile] marker=sca-sanitize-package-name-20260612 (cyclonedx rejects invalid npm names e.g. & in Warda/vite templates)'
  println '[paas-jenkinsfile] marker=angular-legacy-ng-build-20260613 (Angular 9–12: Node16, ng build --progress=false, Step6 timeout 360min)'
  println '[paas-jenkinsfile] marker=nm-snap-skip-resave-step6-20260615 (Step6 skip snapshot re-save when Step3 cache hit; pipefail on tar)'
  println '[paas-jenkinsfile] marker=harbor-nipio-push-coerce-20260615 (always push via harbor.IP.nip.io; probe /v2/ before crane)'
  println '[paas-jenkinsfile] marker=harbor-nipio-artifact-ref-20260615 (PAAS_ARTIFACT_IMAGE + cosign use nip.io push ref)'

  stage("Step 1 — Params validation") {
    println "*** BEGIN : Check Parameters ***"
    nonEmptyNoSpace(gitUrl, "GIT_URL PARAMS")
    nonEmptyNoSpace(branchName, "BRANCH PARAMS")
    nonEmptyNoSpace(imageName, "IMAGE_NAME PARAMS")
    nonEmptyNoSpace(projectId, "PROJECT_ID PARAMS")
    imageName = coerceImageRefRegistryHost(normalizeOciImageReference(resolveImageNameForHarbor(imageName)))
    println "[params] project=${projectId} branch=${branchName} image=${imageName}"
    paasStepOk(1, 'params', "GIT_URL, BRANCH, IMAGE_NAME, PROJECT_ID validated; image=${imageName}")
    println "*** END : Check Parameters ***"
  }

  stage("Step 2 — Checkout du code (Git / GitHub)") {
    println "*** BEGIN : 2. Checkout du code — référentiel Git (GIT_URL / BRANCH) ***"
    deleteDir()
    def host = gitUrl.replaceAll("^https?://([^/@]+).*", "\$1")
    println "[checkout] branch=${branchName} url host=${host} creds=${gitCredentialsId ? 'yes' : 'no'}"
    if (gitCredentialsId) {
      git branch: branchName, credentialsId: gitCredentialsId, url: gitUrl
    } else {
      git branch: branchName, url: gitUrl
    }
    sh '''
      set -eu
      echo "[checkout] workspace root: $(pwd)"
      echo "[checkout] git HEAD: $(git rev-parse HEAD 2>/dev/null || echo 'n/a')"
      echo "[checkout] top of tree:"
      ls -la | head -25
    '''
    def head = sh(script: 'git rev-parse --short HEAD 2>/dev/null || echo unknown', returnStdout: true).trim()
    paasStepOk(2, 'checkout', "branch=${branchName} commit=${head}")
    println "*** END : 2. Checkout du code ***"
  }

  println "[pipeline] Ordre aligné .full : construction (Step 3) puis SCA/SAST (Steps 4–5), puis image → Helm → Artifactory → Cosign → ZAP → Helm OCI → archive (.full §6–14)."

  stage("Step 3 — Construction de l'application") {
    println "*** BEGIN : 5. Construction de l'application ***"
    def buildAppRoot = detectAppRoot()
    def buildFramework = detectProjectFramework(buildAppRoot)
    if (buildAppRoot != '.') {
      println "[build] Monorepo/subdir layout — app root: ${buildAppRoot}"
    }
    println "[build] detected framework: ${buildFramework} (next/angular/nestjs/express/vite-react/spa/node/python)"
    materializeProjectBuildEnv(buildAppRoot)
    patchNextBuildEnvIntoConfig(buildAppRoot)
    if (projectBuildEnvPresent()) {
      sh """
        set -eu
        cd '${buildAppRoot}'
        rm -rf .next
        echo "[env] Cleared .next before build (PROJECT_BUILD_ENV_B64 present)"
      """
    }
    if (fileExists("${buildAppRoot}/pom.xml")) {
      if (commandExists("mvn")) {
        sh "cd '${buildAppRoot}' && mvn -B -DskipTests package"
      } else {
        println "[build] Maven project detected but mvn is not installed; compile skipped."
      }
    } else if (fileExists("${buildAppRoot}/package.json")) {
      patchNextStandaloneConfigIfNeeded(buildAppRoot)
      def dfPath = params.DOCKERFILE_PATH?.trim() ?: 'Dockerfile'
      def deferAngularToStep6 = shouldDeferAngularBuildToStep6(buildAppRoot, dfPath)
      if (deferAngularToStep6) {
        def nodeVer = resolveNodeVersion(buildAppRoot)
        println "[build] Angular/static SPA — skip Step 3 npm build (Step 6 builds dist with Node ${nodeVer} + nginx on port 80)"
      } else if (paasFastPipeline) {
        println "[build] JENKINS_PAAS_FAST_PIPELINE=true — skip workspace npm in Step 3 (npm ci + next build run in Step 6 crane/Docker path)."
      } else {
      ensureNodeTool(resolveNodeVersion(buildAppRoot))
      if (commandExists("npm")) {
        def npmTimeoutMin = 180
        try {
          def raw = (env.BUILD_NODE_NPM_TIMEOUT_MIN ?: "").trim()
          if (raw) {
            npmTimeoutMin = Integer.parseInt(raw)
          }
        } catch (Exception ignored) {
          npmTimeoutMin = 180
        }
        timeout(time: npmTimeoutMin, unit: 'MINUTES') {
          sh '''
            set -e
            cd ''' + buildAppRoot + '''
            export CI=true
            export NEXT_TELEMETRY_DISABLED=1
            export PAAS_FRAMEWORK=''' + buildFramework + '''
            export NODE_OPTIONS="${NODE_OPTIONS:-} --max-old-space-size=${JENKINS_NODE_MAX_OLD_SPACE_MB:-2048}"
            export npm_config_maxsockets="${npm_config_maxsockets:-16}"
''' + paasOpensslLegacyShellSnippet() + '''
            NPM_CACHE="${JENKINS_PAAS_NPM_CACHE:-}"
            if [ -z "${NPM_CACHE}" ] && [ -n "${JENKINS_HOME:-}" ]; then
              NPM_CACHE="${JENKINS_HOME}/.jenkins-paas-cache/npm"
            fi
            if [ -z "${NPM_CACHE}" ] && [ -n "${HOME:-}" ]; then
              NPM_CACHE="${HOME}/.jenkins-paas-cache/npm"
            fi
            if [ -n "${NPM_CACHE}" ]; then
              mkdir -p "${NPM_CACHE}"
              export npm_config_cache="${NPM_CACHE}"
              echo "[build] npm cache dir: ${NPM_CACHE}"
            else
              echo "[build] npm cache: default (set JENKINS_PAAS_NPM_CACHE if no JENKINS_HOME/HOME)"
            fi
            if [ -n "${BUILD_PACKAGE_PROXY_URL:-}" ]; then
              npm config set proxy "$BUILD_PACKAGE_PROXY_URL"
              npm config set https-proxy "$BUILD_PACKAGE_PROXY_URL"
              export HTTP_PROXY="$BUILD_PACKAGE_PROXY_URL"
              export HTTPS_PROXY="$BUILD_PACKAGE_PROXY_URL"
              echo "[build] package proxy: configured (BUILD_PACKAGE_PROXY_URL)"
            else
              echo "[build] package proxy: none (direct egress to registry)"
            fi
            npm config set audit false
            npm config set fund false
            npm config set progress true
            npm config set fetch-retries 5
            npm config set fetch-retry-factor 2
            npm config set fetch-retry-mintimeout 20000
            npm config set fetch-retry-maxtimeout 120000
            npm config set fetch-timeout 1800000
            echo "[build] node $(node -v) npm $(npm -v) registry=$(npm config get registry) maxsockets=$(npm config get maxsockets)"
            JENKINS_SH_KEEPALIVE_SEC="${JENKINS_SH_KEEPALIVE_SEC:-20}"
            run_with_keepalive() {
              if [ "${JENKINS_SH_KEEPALIVE:-true}" != "true" ]; then
                "$@"
                return $?
              fi
              _rwk_sec="${JENKINS_SH_KEEPALIVE_SEC:-20}"
              echo "[build] (keepalive) starting $* at $(date -u +%Y-%m-%dT%H:%M:%SZ) — heartbeat every ${_rwk_sec}s (foreground cmd; JENKINS-48300)"
              ( while true; do
                  sleep "${_rwk_sec}"
                  echo "[build] (keepalive) $* still running $(date -u +%Y-%m-%dT%H:%M:%SZ)"
                done ) &
              _rwk_hb=$!
              "$@"
              _rwk_rc=$?
              kill "${_rwk_hb}" 2>/dev/null || true
              wait "${_rwk_hb}" 2>/dev/null || true
              return "${_rwk_rc}"
            }
            LOG_ARG=""
            if [ -n "${JENKINS_NPM_LOGLEVEL:-}" ]; then
              LOG_ARG="--loglevel ${JENKINS_NPM_LOGLEVEL}"
            fi
            OFFLINE_ARG=""
            if [ "${JENKINS_NPM_CI_PREFER_OFFLINE:-true}" != "false" ]; then
              OFFLINE_ARG="--prefer-offline"
            fi
            LOCK_HASH=""
            LOCK_FILE=""
            for lf in package-lock.json yarn.lock pnpm-lock.yaml; do
              if [ -f "${lf}" ]; then
                LOCK_FILE="${lf}"
                if command -v sha256sum >/dev/null 2>&1; then
                  LOCK_HASH=$(sha256sum "${lf}" | awk '{print $1}')
                else
                  LOCK_HASH=$(openssl dgst -sha256 "${lf}" 2>/dev/null | awk '{print $NF}')
                fi
                break
              fi
            done
            NM_SNAP=""
            NM_SNAP_MAX_MB="${JENKINS_NPM_SNAPSHOT_MAX_MB:-600}"
            if [ "${JENKINS_NPM_SNAPSHOT_NODE_MODULES:-true}" != "false" ] && [ -n "${JENKINS_HOME:-}" ] && [ -n "${LOCK_HASH}" ] && [ -n "${PROJECT_ID:-}" ]; then
              NM_SNAP="${JENKINS_HOME}/.jenkins-paas-cache/nm-snap/${PROJECT_ID}/${LOCK_HASH}"
            fi
            DEPS_OK=0
            if [ -n "${NM_SNAP}" ] && [ -d "${NM_SNAP}" ] && [ -n "$(ls -A "${NM_SNAP}" 2>/dev/null)" ]; then
              SNAP_MB=$(du -sm "${NM_SNAP}" 2>/dev/null | awk '{print $1}' || echo 0)
              if [ -n "${SNAP_MB}" ] && [ "${SNAP_MB}" -gt "${NM_SNAP_MAX_MB}" ] 2>/dev/null; then
                echo "[build] node_modules snapshot ${SNAP_MB}MB > limit ${NM_SNAP_MAX_MB}MB (${LOCK_FILE}) — skip restore; use npm ci (raise JENKINS_NPM_SNAPSHOT_MAX_MB or set JENKINS_NPM_SNAPSHOT_NODE_MODULES=false)"
                NM_SNAP=""
              else
              echo "[build] node_modules snapshot hit → ${NM_SNAP} (${SNAP_MB}MB)"
              rm -rf node_modules
              mkdir -p node_modules
              echo "[build] restoring snapshot via tar (${SNAP_MB}MB)…"
              run_with_keepalive bash -c "tar -C \"${NM_SNAP}\" -cf - . | tar -C node_modules -xf -"
              fi
            fi
            if [ -n "${NM_SNAP}" ] && [ -d "${NM_SNAP}" ] && [ -n "$(ls -A "${NM_SNAP}" 2>/dev/null)" ] && [ -d node_modules ]; then
              if run_with_keepalive npm install --no-audit --no-fund ${OFFLINE_ARG} $LOG_ARG; then
                DEPS_OK=1
                echo "[build] npm install from snapshot OK (skipped full npm ci)"
              else
                echo "[build] snapshot stale or incompatible; removing node_modules and running npm ci"
                rm -rf node_modules
              fi
            fi
            if [ "${DEPS_OK}" != "1" ]; then
              if [ -f package-lock.json ]; then
                run_with_keepalive npm ci --no-audit --no-fund ${OFFLINE_ARG} $LOG_ARG || run_with_keepalive npm install --no-audit --no-fund ${OFFLINE_ARG} $LOG_ARG
              elif [ -f yarn.lock ] && command -v yarn >/dev/null 2>&1; then
                run_with_keepalive yarn install --frozen-lockfile --non-interactive $LOG_ARG || run_with_keepalive npm install --no-audit --no-fund ${OFFLINE_ARG} $LOG_ARG
              else
                run_with_keepalive npm install --no-audit --no-fund ${OFFLINE_ARG} $LOG_ARG
              fi
            fi
            if [ -n "${NM_SNAP}" ] && [ -n "${LOCK_FILE}" ] && [ -f "${LOCK_FILE}" ] && [ -d node_modules ] && [ "${DEPS_OK}" != "1" ]; then
              SNAP_MB=$(du -sm node_modules 2>/dev/null | awk '{print $1}' || echo 0)
              if [ -n "${SNAP_MB}" ] && [ "${SNAP_MB}" -le "${NM_SNAP_MAX_MB}" ] 2>/dev/null; then
                mkdir -p "$(dirname "${NM_SNAP}")"
                rm -rf "${NM_SNAP}.new" "${NM_SNAP}"
                mkdir -p "${NM_SNAP}.new"
                echo "[build] saving node_modules snapshot (${SNAP_MB}MB) via tar…"
                run_with_keepalive bash -c "tar -C node_modules -cf - . | tar -C \"${NM_SNAP}.new\" -xf -"
                mv "${NM_SNAP}.new" "${NM_SNAP}"
                echo "[build] node_modules snapshot saved → ${NM_SNAP}"
              else
                echo "[build] skip saving snapshot (${SNAP_MB}MB > ${NM_SNAP_MAX_MB}MB limit)"
              fi
            fi
            if [ "${JENKINS_SKIP_NEXT_BUILD:-}" = "true" ]; then
              echo "[build] JENKINS_SKIP_NEXT_BUILD=true — pas de next build dans ce stage (dépendances prêtes pour SCA/SAST ; build dans l’image Docker)."
            else
              if node -e "const p=require('./package.json'); const s=p.scripts||{}; process.exit(s['build:ci']?0:1)"; then
                echo "[build] npm run build:ci (script build:ci du dépôt)"
                run_with_keepalive npm run build:ci
              elif [ "${JENKINS_NEXT_BUILD_USE_NPM_SCRIPT:-}" != "true" ] && node -e "const p=require('./package.json');const d={...p.dependencies||{},...p.devDependencies||{}};process.exit(d.next?0:1)"; then
                NB_FLAGS=""
                if node -e "const v=require('next/package.json').version.split('.').map(Number);process.exit((v[0]||0)>=16?0:1)" 2>/dev/null; then
                  echo "[build] Next.js 16+: omitting --no-lint (removed in Next 16 CLI); default bundler is Turbopack. Set JENKINS_NEXT_BUILD_WEBPACK=true for webpack only if needed."
                  if [ "${JENKINS_NEXT_BUILD_WEBPACK:-false}" = "true" ]; then
                    NB_FLAGS="--webpack"
                  fi
                else
                  echo "[build] Next.js 15: --no-lint only (do not pass --webpack — not supported on next build CLI; see Step 6b crane-next16 fix)."
                  NB_FLAGS="--no-lint"
                fi
                if [ "${JENKINS_NEXT_PERSIST_CACHE:-true}" != "false" ] && [ -n "${JENKINS_HOME:-}" ] && [ -n "${PROJECT_ID:-}" ]; then
                  NCROOT="${JENKINS_HOME}/.jenkins-paas-cache/next-cache/${PROJECT_ID}"
                  mkdir -p "$NCROOT" .next
                  rm -rf .next/cache
                  ln -sfn "$NCROOT" .next/cache
                  echo "[build] Next.js cache → $NCROOT (disable: JENKINS_NEXT_PERSIST_CACHE=false)"
                fi
                echo "[build] npx next build ${NB_FLAGS:-"(default bundler)"} — Step 3 aligned with Step 6b (no --webpack unless JENKINS_NEXT_BUILD_WEBPACK=true on Next 16+)"
                _next_hb=""
                if [ "${JENKINS_NEXT_BUILD_HEARTBEAT:-true}" != "false" ]; then
                  _hb_sec="${JENKINS_NEXT_BUILD_HEARTBEAT_SEC:-45}"
                  echo "[build] next build stdout heartbeat every ${_hb_sec}s (disable: JENKINS_NEXT_BUILD_HEARTBEAT=false) — mitigates Jenkins durable-task exit -2 during long quiet Turbopack"
                  ( while true; do echo "[build] (next heartbeat) still building… $(date -u +%Y-%m-%dT%H:%M:%SZ)"; sleep "${_hb_sec}"; done ) &
                  _next_hb=$!
                  trap 'kill "${_next_hb}" 2>/dev/null || true' EXIT
                fi
''' + paasSourceBuildEnvShellSnippet() + '''
                run_with_keepalive npx next build $NB_FLAGS
                if [ -n "${_next_hb}" ]; then kill "${_next_hb}" 2>/dev/null || true; trap - EXIT; fi
                if [ -d .next/standalone ]; then
                  echo "[build] .next/standalone OK — stage 6 will use a small crane layer."
                else
                  echo "[build] WARN: .next/standalone missing — stage 6 may tar the full workspace (slow). Add output: 'standalone' in next.config (see paas/frontend/next.config.mjs)."
                  if [ "${JENKINS_REQUIRE_NEXT_STANDALONE:-false}" = "true" ]; then
                    echo "[build] JENKINS_REQUIRE_NEXT_STANDALONE=true — failing build."
                    exit 1
                  fi
                fi
              elif node -e "const p=require('./package.json'); process.exit(p.scripts && p.scripts.build ? 0 : 1)"; then
                echo "[build] npm run build (${buildFramework}: angular/react/vite/express API with build script)"
                run_with_keepalive npm run build
              else
                echo "[build] Pas de script build — skip (OK for Express API-only; runtime via npm start in image)."
              fi
            fi
          '''
        }
      } else {
        println "[build] Node project detected but npm is not installed; compile skipped."
      }
      }
    } else if (fileExists("${buildAppRoot}/requirements.txt") || fileExists("${buildAppRoot}/pyproject.toml")) {
      if (commandExists("python3")) {
        sh """
          set -eu
          cd '${buildAppRoot}'
          python3 -m compileall . || true
          if [ -f requirements.txt ]; then
            python3 -m pip install --user -q -r requirements.txt || pip3 install --user -q -r requirements.txt || true
          elif [ -f pyproject.toml ]; then
            python3 -m pip install --user -q . || pip3 install --user -q . || true
          fi
        """
      } else {
        println "[build] Python project detected but python3 is not installed; compile skipped."
      }
    } else if (fileExists("requirements.txt") || fileExists("pyproject.toml")) {
      if (commandExists("python3")) {
        sh "python3 -m compileall . || true"
      } else {
        println "[build] Python project detected but python3 is not installed; compile skipped."
      }
    } else {
      println "[build] No Maven/Node/Python manifest found; treating repository as static/Kubernetes manifests."
    }
    sh """
      set +e
      mkdir -p paas-artifacts
      APP_ROOT='${buildAppRoot}'
      STACK=static
      if [ -f "\${APP_ROOT}/pom.xml" ] || [ -f pom.xml ]; then STACK=maven; fi
      if [ -f "\${APP_ROOT}/package.json" ] || [ -f package.json ]; then STACK=node; fi
      if [ -f "\${APP_ROOT}/requirements.txt" ] || [ -f requirements.txt ] || [ -f "\${APP_ROOT}/pyproject.toml" ] || [ -f pyproject.toml ]; then STACK=python; fi
      PATHS=""
      for d in target dist build .next out; do
        if [ -d "\${APP_ROOT}/\$d" ]; then PATHS="\$PATHS \${APP_ROOT}/\$d"; fi
        if [ "\${APP_ROOT}" != "." ] && [ -d "\$d" ]; then PATHS="\$PATHS \$d"; fi
      done
      echo "# 5. Construction — manifeste d'artefacts intermédiaires" > paas-artifacts/build-artifact-manifest.txt
      echo "PROJECT_ID=${projectId}" >> paas-artifacts/build-artifact-manifest.txt
      echo "BRANCH=${branchName}" >> paas-artifacts/build-artifact-manifest.txt
      echo "BUILD_NUMBER=${env.BUILD_NUMBER}" >> paas-artifacts/build-artifact-manifest.txt
      echo "APP_ROOT=\${APP_ROOT}" >> paas-artifacts/build-artifact-manifest.txt
      echo "STACK=\$STACK" >> paas-artifacts/build-artifact-manifest.txt
      if { [ -f "\${APP_ROOT}/pom.xml" ] || [ -f pom.xml ]; } && ls "\${APP_ROOT}"/target/*.jar >/dev/null 2>&1; then
        echo "PRIMARY_ARTIFACTS=\${APP_ROOT}/target/*.jar" >> paas-artifacts/build-artifact-manifest.txt
      elif [ -n "\$PATHS" ]; then
        echo "OUTPUT_DIRS=\$PATHS" >> paas-artifacts/build-artifact-manifest.txt
      else
        echo "OUTPUT_DIRS=(workspace sources / pas de répertoire de sortie détecté)" >> paas-artifacts/build-artifact-manifest.txt
      fi
    """
    def buildProof = 'workspace'
    if (buildAppRoot != '.') { buildProof = "app root ${buildAppRoot}" }
    if (paasFastPipeline && fileExists("${buildAppRoot}/package.json")) {
      buildProof = 'fast-pipeline: compile deferred to Step 6 (crane/Docker)'
    } else if (fileExists("${buildAppRoot}/.next/BUILD_ID")) { buildProof = "${buildAppRoot}/.next build present" }
    else if (fileExists("${buildAppRoot}/target") || fileExists('target')) { buildProof = 'target/ present' }
    else if (fileExists("${buildAppRoot}/dist") || fileExists('dist')) { buildProof = 'dist/ present' }
    else if (fileExists("${buildAppRoot}/build") || fileExists('build')) { buildProof = 'build/ present' }
    paasStepOk(3, 'compile', "${buildProof}; see paas-artifacts/build-artifact-manifest.txt")
    println "*** END : 5. Construction de l'application — voir paas-artifacts/build-artifact-manifest.txt ***"
  }

  stage("Step 4 — Tests SCA (Dependency-Check, CycloneDX, Dependency-Track)") {
    if (paasFastPipeline) {
      paasStepSkip(4, 'JENKINS_PAAS_FAST_PIPELINE=true')
      println "[paas] Fast pipeline: skip Step 4 (SCA / Dependency-Check / cdxgen)."
    } else {
      securityMandatoryStage("3. SCA (Dependency-Check + CycloneDX + Dependency-Track)") {
      dockerAvailable = commandExists("docker")
      sh "mkdir -p sca"
      if (!dockerAvailable) {
        println "[sca] Docker CLI missing; npm audit + @cyclonedx/cyclonedx-npm (Node) or extend agent for full SCA."
        def scaAppRoot = detectAppRoot()
        if (fileExists("${scaAppRoot}/package.json")) {
          ensureNodeTool('20.19.5')
          def scaRc = sh(script: """
            set +e
            cd '${scaAppRoot}'
            mkdir -p sca
            npm audit --json > sca/npm-audit.json 2>/dev/null || true
            node -e '
              const fs=require("fs");
              const slugify=(n)=>String(n||"app").normalize("NFKD").replace(/[^a-zA-Z0-9._-]+/g,"-").replace(/^-+|-+\$/g,"").slice(0,214)||"app";
              const valid=/^(?:@[a-z0-9-~][a-z0-9-._~]*\\/)?[a-z0-9-~][a-z0-9-._~]*\$/i;
              const patch=(f)=>{ if(!fs.existsSync(f)) return; const j=JSON.parse(fs.readFileSync(f,"utf8")); const n=j.name||""; if(valid.test(n)) return; const s=slugify(n); console.log("[sca] invalid npm name "+JSON.stringify(n)+" -> "+s+" (cyclonedx-npm)"); j.name=s; fs.writeFileSync(f, JSON.stringify(j,null,2)+"\\n"); };
              patch("package.json"); patch("package-lock.json");
            ' 2>/dev/null || true
            CDX_RC=254
            if [ -f yarn.lock ]; then
              echo "[sca] cyclonedx-npm (yarn.lock — do not use --package-lock-only)"
              npx --yes @cyclonedx/cyclonedx-npm --output-file sca/bom.json
              CDX_RC=\$?
            elif [ -f package-lock.json ]; then
              echo "[sca] cyclonedx-npm (package-lock.json)"
              npx --yes @cyclonedx/cyclonedx-npm --package-lock-only --output-file sca/bom.json
              CDX_RC=\$?
              if [ "\${CDX_RC}" != "0" ] || [ ! -f sca/bom.json ]; then
                echo "[sca] cyclonedx-npm retry from node_modules (npm ls ELSPROBLEMS workaround)"
                npx --yes @cyclonedx/cyclonedx-npm --output-file sca/bom.json
                CDX_RC=\$?
              fi
            elif [ -f pnpm-lock.yaml ]; then
              npx --yes @cyclonedx/cyclonedx-npm --output-file sca/bom.json
              CDX_RC=\$?
            else
              echo "[sca] no lockfile — full npm install then cyclonedx-npm (package-lock-only leaves ELSPROBLEMS / empty node_modules)"
              if [ ! -d node_modules ] || [ ! -f package-lock.json ]; then
                npm install --no-audit --no-fund
              fi
              if [ -f package-lock.json ]; then
                npx --yes @cyclonedx/cyclonedx-npm --package-lock-only --output-file sca/bom.json
                CDX_RC=\$?
              fi
              if [ "\${CDX_RC}" != "0" ] || [ ! -f sca/bom.json ]; then
                npx --yes @cyclonedx/cyclonedx-npm --output-file sca/bom.json
                CDX_RC=\$?
              fi
            fi
            echo \${CDX_RC}
          """, returnStdout: true).trim().tokenize('\n').last()
          if (scaRc != "0" || !fileExists("${scaAppRoot}/sca/bom.json")) {
            paasStepFail(4, 'sca', "bom.json missing or cyclonedx failed (rc=${scaRc}) — yarn: use yarn.lock path; npm: package-lock.json; or enable Docker for cdxgen")
          } else {
            paasStepOk(4, 'sca', 'sca/bom.json generated (cyclonedx-npm)')
          }
          if (fileExists("${scaAppRoot}/sca/bom.json") && !fileExists("sca/bom.json")) {
            sh "mkdir -p sca && cp '${scaAppRoot}/sca/bom.json' sca/bom.json"
          }
        } else {
          def scaPyRoot = detectAppRoot()
          if (fileExists("${scaPyRoot}/requirements.txt") || fileExists("${scaPyRoot}/pyproject.toml")) {
            def pyScaRc = sh(script: """
              set +e
              cd '${scaPyRoot}'
              mkdir -p sca
              python3 -m pip install --user -q cyclonedx-bom 2>/dev/null || pip3 install --user -q cyclonedx-bom 2>/dev/null || true
              if command -v cyclonedx-py >/dev/null 2>&1; then
                if [ -f requirements.txt ]; then
                  cyclonedx-py requirements -i requirements.txt -o sca/bom.json
                else
                  cyclonedx-py environment -o sca/bom.json
                fi
              else
                python3 -m pip freeze > sca/requirements-freeze.txt 2>/dev/null || true
              fi
              test -f sca/bom.json && echo 0 || echo 1
            """, returnStdout: true).trim().tokenize('\n').last()
            if (pyScaRc == "0") {
              paasStepOk(4, 'sca', 'sca/bom.json generated (cyclonedx-py)')
              if (fileExists("${scaPyRoot}/sca/bom.json") && !fileExists("sca/bom.json")) {
                sh "mkdir -p sca && cp '${scaPyRoot}/sca/bom.json' sca/bom.json"
              }
            } else {
              paasStepFail(4, 'sca', 'Python SBOM missing — pip install cyclonedx-bom or enable Docker for cdxgen')
            }
          } else {
            paasStepFail(4, 'sca', 'No package.json or Python manifest — enable Docker on Jenkins agent for full OWASP scan')
          }
        }
        uploadBomToDependencyTrack(projectId, dtProjectNameForUpload(projectId, imageName), branchName)
        if (!fileExists('sca/bom.json')) {
          paasStepFail(4, 'sca', 'No sca/bom.json after SCA — check cyclonedx/cdxgen logs')
        }
        return
      }
      def nvdArg = env.NVD_API_KEY?.trim() ? "--nvdApiKey ${env.NVD_API_KEY}" : "--noupdate"
      withEnv([
        "PAAS_SCA_WORKSPACE=${env.WORKSPACE ?: ''}",
        "PAAS_SCA_NVD_ARG=${nvdArg}"
      ]) {
        sh '''#!/bin/bash
set +u
if [ -z "${PAAS_SCA_WORKSPACE}" ]; then
  export WORKSPACE="$(pwd)"
else
  export WORKSPACE="${PAAS_SCA_WORKSPACE}"
fi
set +e
mkdir -p "${WORKSPACE}/sca"
echo "[sca] OWASP Dependency-Check: scan des dépendances vs NVD → JSON..."
docker pull owasp/dependency-check:latest >/dev/null
docker run --rm -v "${WORKSPACE}:/src" owasp/dependency-check:latest \
  --scan /src --format JSON --out /src/sca ${PAAS_SCA_NVD_ARG} || true
if [ -f "${WORKSPACE}/sca/dependency-check-report.json" ]; then
  mv -f "${WORKSPACE}/sca/dependency-check-report.json" "${WORKSPACE}/sca/dependency-check.json"
fi
echo "[sca] Génération SBOM CycloneDX (bom.json) pour Dependency-Track..."
CDXGEN_IMG="ghcr.io/cyclonedx/cdxgen:latest"
docker pull "${CDXGEN_IMG}" >/dev/null || echo "[sca] cdxgen image pull failed"
if [ -f "${WORKSPACE}/package.json" ] || [ -f "${WORKSPACE}/package-lock.json" ] || [ -f "${WORKSPACE}/yarn.lock" ] || [ -f "${WORKSPACE}/pnpm-lock.yaml" ]; then
  docker run --rm -v "${WORKSPACE}:/repo" -w /repo "${CDXGEN_IMG}" \
    -r /repo -o /repo/sca/bom.json || true
elif [ -f "${WORKSPACE}/pom.xml" ] || [ -f "${WORKSPACE}/build.gradle" ] || [ -f "${WORKSPACE}/build.gradle.kts" ]; then
  docker run --rm -v "${WORKSPACE}:/repo" -w /repo "${CDXGEN_IMG}" \
    -t java -r /repo -o /repo/sca/bom.json || true
elif [ -f "${WORKSPACE}/requirements.txt" ] || [ -f "${WORKSPACE}/pyproject.toml" ] || [ -f "${WORKSPACE}/Pipfile.lock" ]; then
  docker run --rm -v "${WORKSPACE}:/repo" -w /repo "${CDXGEN_IMG}" \
    -t python -r /repo -o /repo/sca/bom.json || true
else
  echo "[sca] Manifeste non reconnu par cdxgen; bom.json peut être absent."
fi
if [ -f "${WORKSPACE}/sca/bom.json" ]; then
  echo "[sca] SBOM: ${WORKSPACE}/sca/bom.json"
else
  echo "[sca] Pas de bom.json généré."
fi
exit 0
'''
      }
      uploadBomToDependencyTrack(projectId, dtProjectNameForUpload(projectId, imageName), branchName)
      if (fileExists('sca/bom.json')) {
        paasStepOk(4, 'sca', 'sca/bom.json present (Dependency-Check + CycloneDX)')
      } else {
        paasStepFail(4, 'sca', 'sca/bom.json missing — check Docker and NVD_API_KEY in console')
      }
    }
    }
  }

  stage("Step 5 — Tests SAST (SonarQube)") {
    if (paasFastPipeline) {
      paasStepSkip(5, 'JENKINS_PAAS_FAST_PIPELINE=true')
      println "[paas] Fast pipeline: skip Step 5 (SonarQube)."
    } else {
      securityMandatoryStage("4. SAST — SonarQube") {
      println "[paas-jenkinsfile] marker=sonar-scanner-cli6-login-20260607 (sonar.login+token; cluster URL; ws.timeout=300; retries)"
      def sonarKey = dtProjectNameForUpload(projectId, imageName)
      def sonarUrlParam = params.SONAR_HOST_URL?.trim() ?: env.SONAR_HOST_URL ?: ""
      def sonarToken = params.SONAR_TOKEN?.trim() ?: env.SONAR_TOKEN ?: ""
      if (!sonarUrlParam || !sonarToken) {
        paasStepFail(5, 'sonar', 'SONAR_HOST_URL and SONAR_TOKEN are required on Jenkins job')
      }
      if (!commandExists("docker")) {
        println "[sonar] Docker CLI missing; using npm-based Sonar scanner when configured."
        ensureNodeTool()
        prependPath("/opt/java/openjdk/bin")
        withEnv([
          "SONAR_HOST_URL_PARAM=${sonarUrlParam}",
          "SONAR_TOKEN=${sonarToken}",
          "SONAR_PROJECT_KEY=${sonarKey}",
          "SONAR_PROJECT_ID_TAG=${projectId}",
          "SONAR_VERSION=${branchName}-${env.BUILD_NUMBER}"
        ]) {
          def sonarRc = sh(script: '''#!/bin/bash
            set +e
            pick_sonar_url() {
              # Prefer in-cluster Sonar (faster than NodePort; NodePort can timeout on values.protobuf).
              for u in \
                "http://sonarqube-sonarqube.sonarqube.svc.cluster.local:9000" \
                "http://sonarqube-service.sonarqube.svc.cluster.local:9000" \
                "http://sonarqube.sonarqube.svc.cluster.local:9000" \
                "${SONAR_HOST_URL_PARAM}"
              do
                [ -z "$u" ] && continue
                if curl -fsS -m 15 -u "${SONAR_TOKEN}:" "${u%/}/api/system/status" >/dev/null 2>&1; then
                  echo "$u"
                  return 0
                fi
              done
              echo "${SONAR_HOST_URL_PARAM}"
            }
            SONAR_HOST_URL="$(pick_sonar_url)"
            echo "[sonar] using ${SONAR_HOST_URL}"
            VALID=$(curl -sS -m 8 -u "${SONAR_TOKEN}:" "${SONAR_HOST_URL%/}/api/authentication/validate" 2>/dev/null || true)
            echo "[sonar] token validate: ${VALID:-<curl failed>}"
            if ! printf '%s' "${VALID}" | grep -q '"valid":true'; then
              echo "[sonar] token not valid from Jenkins agent — check SONAR_TOKEN and Sonar URL reachability"
              exit 1
            fi
            curl -sS -u "${SONAR_TOKEN}:" -X POST \
              "${SONAR_HOST_URL%/}/api/projects/create?project=${SONAR_PROJECT_KEY}&name=${SONAR_PROJECT_KEY}" \
              >/dev/null 2>&1 || true
            SOURCES="."
            for d in app src components pages lib server; do
              if [ -d "$d" ]; then
                SOURCES="$d"
                break
              fi
            done
            echo "[sonar] sources=${SOURCES}"
            SP=sonar-project.properties
            rm -f "${SP}"
            {
              printf 'sonar.host.url=%s\n' "${SONAR_HOST_URL}"
              printf 'sonar.token=%s\n' "${SONAR_TOKEN}"
              printf 'sonar.login=%s\n' "${SONAR_TOKEN}"
              printf 'sonar.projectKey=%s\n' "${SONAR_PROJECT_KEY}"
              printf 'sonar.projectName=%s\n' "${SONAR_PROJECT_KEY}"
              printf 'sonar.projectVersion=%s\n' "${SONAR_VERSION}"
              printf 'sonar.sources=%s\n' "${SOURCES}"
              printf 'sonar.exclusions=%s\n' '**/node_modules/**,**/.next/**,**/dist/**,**/build/**,**/.git/**,**/coverage/**,**/*.min.js'
              printf 'sonar.qualitygate.wait=%s\n' 'true'
              printf 'sonar.scanner.analysisCacheEnabled=%s\n' 'false'
              printf 'sonar.ws.timeout=%s\n' '300'
            } > "${SP}"
            chmod 600 "${SP}"
            echo "[sonar] wrote ${SP} (credentials in file; not echoed)"
            if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ]; then
              export PATH="${JAVA_HOME}/bin:${PATH}"
            fi
            if ! command -v java >/dev/null 2>&1; then
              for _jb in /opt/java/openjdk/bin/java /usr/lib/jvm/java-17-openjdk-amd64/bin/java; do
                if [ -x "${_jb}" ]; then
                  export PATH="$(dirname "${_jb}"):${PATH}"
                  export JAVA_HOME="$(dirname "$(dirname "${_jb}")")"
                  break
                fi
              done
            fi
            if ! command -v java >/dev/null 2>&1; then
              echo "[sonar] ERROR: java not in PATH (sonarqube-scanner needs JRE). Jenkins image usually has JAVA_HOME — set JAVA_HOME on the Jenkins deployment or install openjdk-17-jre in the cicd/jenkins pod."
              exit 1
            fi
            echo "[sonar] java: $(java -version 2>&1 | head -1)"
            mkdir -p paas-artifacts
            LOG=paas-artifacts/sonar-scanner.log
            # SonarScanner CLI 6.x: token via env + -D (properties alone is not enough).
            export SONAR_TOKEN="${SONAR_TOKEN}"
            export SONAR_HOST_URL="${SONAR_HOST_URL}"
            RC=1
            for _sonar_try in 1 2 3; do
              echo "[sonar] scanner attempt ${_sonar_try}/3"
              npx --yes sonarqube-scanner@4.2.8 \
                -Dsonar.host.url="${SONAR_HOST_URL}" \
                -Dsonar.token="${SONAR_TOKEN}" \
                -Dsonar.login="${SONAR_TOKEN}" \
                -Dsonar.ws.timeout=300 \
                > "${LOG}" 2>&1
              RC=$?
              if [ "${RC}" = "0" ]; then
                break
              fi
              if grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' "${LOG}"; then
                RC=0
                break
              fi
              if grep -qE 'SocketTimeoutException|Read timed out|values\\.protobuf' "${LOG}" && [ "${_sonar_try}" -lt 3 ]; then
                echo "[sonar] WARN: Sonar API timeout — retry in 30s (check Sonar at SONAR_BASE_URL if persistent)"
                sleep 30
                continue
              fi
              break
            done
            cat "${LOG}"
            if [ "${RC}" != "0" ] && grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' "${LOG}"; then
              echo "[sonar] scanner reported success despite exit ${RC} — treating as OK"
              RC=0
            fi
            if [ "${RC}" != "0" ]; then
              echo "[sonar] scanner tail:"
              tail -40 "${LOG}" 2>/dev/null || true
            fi
            rm -f "${SP}"
            exit "${RC}"
          ''', returnStatus: true)
          def sonarLog = fileExists('paas-artifacts/sonar-scanner.log') ? readFile('paas-artifacts/sonar-scanner.log') : ''
          def sonarPassed = (sonarRc as Integer) == 0 \
            || sonarLog.contains('EXECUTION SUCCESS') \
            || sonarLog.contains('ANALYSIS SUCCESSFUL')
          if (sonarPassed) {
            paasStepOk(5, 'sonar', "analysis submitted for projectKey=${sonarKey}")
          } else {
            paasStepFail(5, 'sonar', "scanner exit ${sonarRc} — see paas-artifacts/sonar-scanner.log; verify SONAR_BASE_URL and SONAR_TOKEN in PaaS env")
          }
        }
        return
      }
      withEnv([
        "SONAR_SCAN_HOST_URL=${sonarUrlParam}",
        "SONAR_SCAN_TOKEN=${sonarToken}",
        "SONAR_SCAN_WORKSPACE=${env.WORKSPACE ?: ''}",
        "SONAR_SCAN_PROJECT_KEY=${sonarKey}",
        "SONAR_SCAN_PROJECT_VERSION=${branchName}-${env.BUILD_NUMBER}"
      ]) {
        def sonarDockerRc = sh(script: '''#!/bin/bash
set +e
SONAR_WS="${SONAR_SCAN_WORKSPACE}"
if [ -z "${SONAR_WS}" ]; then SONAR_WS="$(pwd)"; fi
for u in "${SONAR_SCAN_HOST_URL}" \
  "http://sonarqube-sonarqube.sonarqube.svc.cluster.local:9000" \
  "http://sonarqube-service.sonarqube.svc.cluster.local:9000"; do
  if curl -fsS -m 8 -u "${SONAR_SCAN_TOKEN}:" "${u%/}/api/system/status" >/dev/null 2>&1; then
    SONAR_SCAN_HOST_URL="$u"
    break
  fi
done
echo "[sonar] docker scanner host=${SONAR_SCAN_HOST_URL}"
SP="${SONAR_WS}/sonar-project.properties"
cat > "${SP}" <<SONARPROP
sonar.host.url=${SONAR_SCAN_HOST_URL}
sonar.token=${SONAR_SCAN_TOKEN}
sonar.login=${SONAR_SCAN_TOKEN}
sonar.projectKey=${SONAR_SCAN_PROJECT_KEY}
sonar.ws.timeout=300
sonar.projectName=${SONAR_SCAN_PROJECT_KEY}
sonar.projectVersion=${SONAR_SCAN_PROJECT_VERSION}
sonar.sources=app,src,components,pages,lib
sonar.exclusions=**/node_modules/**,**/.next/**,**/dist/**,**/build/**,**/.git/**
sonar.qualitygate.wait=true
sonar.scm.provider=git
SONARPROP
chmod 600 "${SP}"
docker pull sonarsource/sonar-scanner-cli:latest >/dev/null
docker run --rm \
  --add-host=host.docker.internal:host-gateway \
  -e SONAR_HOST_URL="$SONAR_SCAN_HOST_URL" \
  -e SONAR_LOGIN="$SONAR_SCAN_TOKEN" \
  -e SONAR_TOKEN="$SONAR_SCAN_TOKEN" \
  -v "${SONAR_WS}:/usr/src" \
  sonarsource/sonar-scanner-cli:latest
echo $?
''', returnStdout: true).trim().tokenize('\n').last()
        if (sonarDockerRc != "0") {
          paasStepFail(5, 'sonar', "scanner exit ${sonarDockerRc} — check SONAR_TOKEN / URL from Jenkins agent")
        } else {
          paasStepOk(5, 'sonar', "analysis submitted for projectKey=${sonarKey}")
        }
      }
    }
    }
  }

    stage("Step 6 — Création de l'image Docker") {
    println "*** BEGIN : 6. Création de l'image Docker (aligné Jenkinsfile.paas-deploy.full) ***"
    def step6AppRoot = detectAppRoot()
    materializeProjectBuildEnv(step6AppRoot)
    patchNextBuildEnvIntoConfig(step6AppRoot)
    dockerAvailable = commandExists("docker")
    def rawDest = normalizeOciImageReference("${imageName}:${env.BUILD_NUMBER}")
    def dest = resolveHarborPushImageRef(rawDest)
    if (dest != rawDest) {
      println "[image] coerced artifact ref: ${rawDest} → ${dest}"
    }
    def df = params.DOCKERFILE_PATH?.trim() ?: "Dockerfile"
    def ctx = params.DOCKER_BUILD_CONTEXT?.trim() ?: "."
    imagePushPending = false
    imagePublishedViaCrane = false
    cosignImageRef = ""
    if (!dockerAvailable) {
      println "[image] Pas de Docker CLI : construction + envoi des couches OCI via crane (Harbor ou Docker Hub)."
      def resolvedDockerfile = dockerfileForDetectedProject(df)
      if (!resolvedDockerfile) {
        artifactImage = params.FALLBACK_IMAGE?.trim() ?: "nginx:stable-alpine"
        println "[image] No build manifest found; using fallback image ${artifactImage}"
        println "PAAS_ARTIFACT_IMAGE=${artifactImage}"
            sh """
          set +e
          mkdir -p paas-artifacts
          echo "PAAS_ARTIFACT_IMAGE=${artifactImage}" >> paas-artifacts/build-artifact-manifest.txt
        """
        println "*** END : 6. Création de l'image Docker ***"
        return
      }
      if (fileExists("${step6AppRoot}/package.json")) {
        ensureNodeTool(resolveNodeVersion(step6AppRoot))
      }
      def craneBin = ensureCraneTool()
      def step6TimeoutMin = cranePushTimeoutMin
      if (isLegacyAngularProject(step6AppRoot)) {
        step6TimeoutMin = Math.max(step6TimeoutMin, 360)
        println "[image] legacy Angular ivy build — Step 6 timeout ${step6TimeoutMin} min (set JENKINS_CRANE_PUSH_TIMEOUT_MIN to override)"
      } else {
        println "[image] dockerless crane: durable-task timeout ${step6TimeoutMin} min (set JENKINS_CRANE_PUSH_TIMEOUT_MIN to override)"
      }
      timeout(time: step6TimeoutMin, unit: 'MINUTES') {
        dockerlessImagePush(craneBin, dest, resolvedDockerfile)
      }
      artifactImage = dest
      imagePublishedViaCrane = true
      cosignImageRef = dest
      println "PAAS_ARTIFACT_IMAGE=${artifactImage}"
    } else {
      def resolvedDockerfile = dockerfileForDetectedProject(df)
      if (!resolvedDockerfile) {
        error("Need Dockerfile, package.json, requirements.txt, or pyproject.toml")
      }
      sh "docker build -f '${resolvedDockerfile}' -t '${dest}' '${ctx}'"
      artifactImage = dest
      cosignImageRef = dest
      imagePushPending = true
      println "PAAS_ARTIFACT_IMAGE=${artifactImage}"
    }
    if (imagePushPending) {
      println "[image] Publication registre (équivalent .full §9)…"
      if (env.HARBOR_REGISTRY?.trim() && env.HARBOR_USERNAME?.trim() && env.HARBOR_PASSWORD?.trim()) {
        sh """
          set -eu
          echo "\${HARBOR_PASSWORD}" | docker login "\${HARBOR_REGISTRY}" -u "\${HARBOR_USERNAME}" --password-stdin
          docker push '${dest}'
        """
      } else {
        def dockerCred = params.DOCKER_REGISTRY_CREDENTIALS_ID?.trim()
        if (dockerCred) {
          def registry = imageName.split("/")[0]
          withCredentials([usernamePassword(credentialsId: dockerCred, usernameVariable: "REGISTRY_USER", passwordVariable: "REGISTRY_PASS")]) {
            sh """
              set -eu
              echo "\${REGISTRY_PASS}" | docker login '${registry}' -u "\${REGISTRY_USER}" --password-stdin
              docker push '${dest}'
            """
          }
        } else if (env.DOCKERHUB_USERNAME?.trim() && env.DOCKERHUB_TOKEN?.trim()) {
          withEnv(["DHU=${env.DOCKERHUB_USERNAME}", "DHT=${env.DOCKERHUB_TOKEN}", "IMG=${dest}"]) {
            sh '''
              set -eu
              echo "$DHT" | docker login -u "$DHU" --password-stdin
              docker push "$IMG"
            '''
          }
        } else {
          println "[image] WARN: image construite localement mais non poussée — renseignez HARBOR_*, DOCKER_REGISTRY_CREDENTIALS_ID, ou DOCKERHUB_USERNAME+TOKEN."
        }
      }
    }
    sh """
      set +e
      mkdir -p paas-artifacts
      echo "PAAS_ARTIFACT_IMAGE=${artifactImage}" >> paas-artifacts/build-artifact-manifest.txt
    """
    paasStepOk(6, 'image', "artifact=${artifactImage} crane=${imagePublishedViaCrane}")
    println "*** END : 6. Création de l'image Docker ***"
  }

  stage("Step 7 — Packaging du chart Helm") {
    nonFatalStage("7. Packaging du chart Helm (aligné Jenkinsfile.paas-deploy.full)") {
      sh """
        set -eu
        mkdir -p paas-artifacts
        cat > paas-artifacts/release-metadata.txt <<EOF
PROJECT_ID=${projectId}
BRANCH=${branchName}
BUILD_NUMBER=${env.BUILD_NUMBER}
PAAS_ARTIFACT_IMAGE=${artifactImage}
EOF
      """
      if (fileExists("Chart.yaml") && commandExists("helm")) {
        sh "mkdir -p paas-artifacts/helm && helm package . --destination paas-artifacts/helm"
        println "[helm] Chart packagé : paas-artifacts/helm/*.tgz (déploiement Kubernetes via Helm / GitOps)."
      } else {
        println "[helm] Pas de Chart.yaml à la racine ou CLI helm absente ; le packaging est délégué au dépôt GitOps du PaaS."
      }
      if (fileExists('paas-artifacts/release-metadata.txt')) {
        paasStepOk(7, 'helm_meta', 'paas-artifacts/release-metadata.txt written')
      } else {
        paasStepWarn(7, 'helm_meta', 'release-metadata missing')
      }
    }
  }

  stage("Step 8 — Publication des artefacts (Artifactory)") {
    if (paasFastPipeline) {
      paasStepSkip(8, 'JENKINS_PAAS_FAST_PIPELINE=true')
      println "[paas] Fast pipeline: skip Step 8 (Artifactory bundle upload)."
    } else {
      nonFatalStage("8. Publication Artifactory (aligné Jenkinsfile.paas-deploy.full)") {
      def artiBase = (params.ARTIFACTORY_URL?.trim() ?: env.ARTIFACTORY_URL ?: "").trim()
      def artiRepo = (params.ARTIFACTORY_REPOSITORY?.trim() ?: env.ARTIFACTORY_REPOSITORY ?: "libs-release-local").trim()
      def credId = params.ARTIFACTORY_CREDENTIALS_ID?.trim() ?: ""
      def bearer = env.ARTIFACTORY_ACCESS_TOKEN?.trim() ?: ""
      def basicUser = env.ARTIFACTORY_USERNAME?.trim() ?: ""
      def basicPass = env.ARTIFACTORY_PASSWORD?.trim() ?: ""
      if (!artiBase) {
        println "[artifactory] ARTIFACTORY_URL absent — étape ignorée (optionnel)."
        return
      }
      def destUrl = "${artiBase.replaceAll(/\/$/, '')}/${artiRepo}/paas-builds/${projectId}/${env.BUILD_NUMBER}/paas-build-${env.BUILD_NUMBER}.tgz"
      def uploadShell = '''
        set +e
        rm -f paas-jenkins-bundle.tgz
        if [ -d paas-artifacts ] || [ -d sca ]; then
          tar -czf paas-jenkins-bundle.tgz paas-artifacts sca 2>/dev/null || tar -czf paas-jenkins-bundle.tgz paas-artifacts 2>/dev/null || tar -czf paas-jenkins-bundle.tgz sca 2>/dev/null
        fi
        if [ ! -f paas-jenkins-bundle.tgz ]; then
          echo "[artifactory] Aucun répertoire paas-artifacts ou sca à publier."
          exit 0
        fi
        if [ "${USE_BEARER}" = "1" ] && [ -n "${ARTI_BEARER:-}" ]; then
          curl -f -sS --connect-timeout 15 --max-time 300 -H "Authorization: Bearer ${ARTI_BEARER}" -T paas-jenkins-bundle.tgz "${ARTI_DEST}" || exit 1
        elif [ -n "${ARTI_USER:-}" ]; then
          curl -f -sS --connect-timeout 15 --max-time 300 -u "${ARTI_USER}:${ARTI_PASS}" -T paas-jenkins-bundle.tgz "${ARTI_DEST}" || exit 1
        else
          echo "[artifactory] Authentification manquante."
          exit 1
        fi
        echo "[artifactory] Publié : ${ARTI_DEST}"
      '''
      if (credId) {
        withCredentials([usernamePassword(credentialsId: credId, usernameVariable: "ARTI_USER", passwordVariable: "ARTI_PASS")]) {
          withEnv(["ARTI_DEST=${destUrl}", "USE_BEARER=0"]) {
            sh uploadShell
          }
        }
      } else if (bearer) {
        withEnv(["ARTI_DEST=${destUrl}", "USE_BEARER=1", "ARTI_BEARER=${bearer}", "ARTI_USER=", "ARTI_PASS="]) {
          sh uploadShell
        }
      } else if (basicUser && basicPass) {
        withEnv(["ARTI_DEST=${destUrl}", "USE_BEARER=0", "ARTI_USER=${basicUser}", "ARTI_PASS=${basicPass}"]) {
          sh uploadShell
        }
      } else {
        println "[artifactory] Définir ARTIFACTORY_CREDENTIALS_ID (Jenkins) ou ACCESS_TOKEN ou USER+PASSWORD — étape ignorée."
      }
      paasStepOk(8, 'artifactory', 'stage finished (upload optional if ARTIFACTORY_URL set)')
    }
    }
  }

  stage("Step 9 — Signature de l'image (Cosign)") {
    securityMandatoryStage("10. Cosign (aligné Jenkinsfile.paas-deploy.full)") {
      if (!cosignImageRef?.trim()) {
        paasStepFail(9, 'cosign', 'no image built — cannot sign')
      }
      cosignImageRef = coerceImageRefRegistryHost(normalizeOciImageReference(cosignImageRef))
      println "[cosign] signing ref (nip.io when Harbor IP): ${cosignImageRef}"
      def credId = params.COSIGN_CREDENTIALS_ID?.trim() ?: ""
      def labKeyPath = "/var/jenkins_home/cosign-lab/cosign.key"
      def pemFromEnv = normalizeCosignPrivateKeyPem(env.COSIGN_PRIVATE_KEY ?: "")
      if (!credId && !pemFromEnv && !fileExists(labKeyPath)) {
        paasStepFail(9, 'cosign', 'COSIGN_CREDENTIALS_ID, COSIGN_PRIVATE_KEY, or lab key required')
      }
      def cosignExe
      try {
        cosignExe = ensureCosignTool()
      } catch (Throwable cosignToolErr) {
        paasStepFail(9, 'cosign', "tool bootstrap failed: ${cosignToolErr.message?.take(200)}")
      }
      def insecureFlag = "--allow-insecure-registry"
      def craneBinCosign = ""
      if (imagePublishedViaCrane) {
        try {
          craneBinCosign = ensureCraneTool()
        } catch (Throwable ignored) {
          println "[cosign] crane unavailable for digest resolve — tag sign only"
        }
      }
      if (commandExists("docker") && env.HARBOR_REGISTRY?.trim() && env.HARBOR_USERNAME?.trim() && env.HARBOR_PASSWORD?.trim()) {
        sh """
          set +e
          echo "\${HARBOR_PASSWORD}" | docker login "\${HARBOR_REGISTRY}" -u "\${HARBOR_USERNAME}" --password-stdin
        """
      }
      def cosignEnvBase = [
        "COSIGN_EXE=${cosignExe}",
        "COSIGN_IMG=${cosignImageRef}",
        "INSEC=${insecureFlag}",
        "COSIGN_PASSWORD=${env.COSIGN_PASSWORD ?: ""}",
        "CRANE_BIN=${craneBinCosign}"
      ]
      def cosignSignSh = cosignSignImageShellSnippet()
      def runCosignSign = {
        timeout(time: 8, unit: 'MINUTES') {
          sh cosignSignSh
        }
      }
      if (credId) {
        withCredentials([file(credentialsId: credId, variable: "COSIGN_KEY_FILE")]) {
          withEnv(cosignEnvBase) {
            runCosignSign()
          }
        }
      } else if (fileExists(labKeyPath)) {
        println "[cosign] Using lab key file ${labKeyPath}"
        withEnv(cosignEnvBase + ["LAB_KEY=${labKeyPath}"]) {
          runCosignSign()
        }
      } else {
        writeFile file: "paas-cosign-private.key", text: pemFromEnv
        withEnv(cosignEnvBase) {
          timeout(time: 8, unit: 'MINUTES') {
            sh "chmod 600 paas-cosign-private.key\n${cosignSignSh}\nrm -f paas-cosign-private.key"
          }
        }
      }
      paasStepOk(9, 'cosign', cosignImageRef ? "sign attempted for ${cosignImageRef}" : 'no image to sign')
    }
  }

  stage("Step 10 — DAST (OWASP ZAP baseline)") {
    if (paasFastPipeline) {
      paasStepSkip(10, 'JENKINS_PAAS_FAST_PIPELINE=true')
      println "[paas] Fast pipeline: skip Step 10 (OWASP ZAP baseline)."
    } else {
      nonFatalStage("10b. ZAP baseline (aligné Jenkinsfile.paas-deploy.full)") {
      def zapTarget = params.ZAP_TARGET_URL?.trim() ?: env.ZAP_TARGET_URL?.trim() ?: ""
      if (!zapTarget) {
        println "[zap] ZAP_TARGET_URL absent — étape ignorée."
        return
      }
      if (!commandExists("docker")) {
        println "[zap] docker CLI absent — ZAP baseline ignoré."
        return
      }
      println "[zap] Cible DAST: ${zapTarget}"
      withEnv(["ZAP_TARGET=${zapTarget}"]) {
        sh '''
          set +e
          mkdir -p paas-artifacts
          docker run --rm \
            -v "$PWD/paas-artifacts:/zap/wrk/:rw" \
            ghcr.io/zaproxy/zaproxy:stable \
            zap-baseline.py -t "$ZAP_TARGET" \
              -r /zap/wrk/zap-baseline-report.html \
              -J /zap/wrk/zap-baseline-report.json
          echo "[zap] zap-baseline exit code: $? (0=pass, 1=fail, 2=warnings) — stage non-bloquante"
        '''
      }
      if (fileExists('paas-artifacts/zap-baseline-report.html')) {
        paasStepOk(10, 'zap', 'ZAP report in paas-artifacts/')
      } else {
        paasStepWarn(10, 'zap', 'ZAP skipped or no report (set ZAP_TARGET_URL)')
      }
    }
    }
  }

  stage("Step 11 — Publication charts Helm (OCI → Harbor)") {
    nonFatalStage("11. Publication Helm OCI → Harbor (aligné Jenkinsfile.paas-deploy.full)") {
      def reg = (env.HARBOR_REGISTRY ?: "").trim()
      def hu = (env.HARBOR_USERNAME ?: "").trim()
      def hp = (env.HARBOR_PASSWORD ?: "").trim()
      def ociProj = (params.HELM_OCI_PROJECT?.trim() ?: env.HELM_OCI_PROJECT?.trim() ?: "paas")
      if (!reg || !hu || !hp) {
        println "[helm-oci] HARBOR_REGISTRY / HARBOR_USERNAME / HARBOR_PASSWORD requis — publication Helm ignorée."
        return
      }
      if (!commandExists("helm")) {
        println "[helm-oci] helm CLI absent — publication ignorée."
        return
      }
      if (!fileExists("paas-artifacts/helm")) {
        println "[helm-oci] Pas de paas-artifacts/helm (exécutez d'abord le packaging Step 7) — ignoré."
        return
      }
      def regHost = reg.replaceFirst("^https?://", "").replaceAll(/\/$/, "")
      def ociRef = "oci://${regHost}/${ociProj}"
      withEnv(["HELM_OCI_REF=${ociRef}", "REG_HOST=${regHost}"]) {
        sh '''
          set +e
          shopt -s nullglob
          LOGIN_OPTS=""
          if [ "${HELM_OCI_INSECURE:-}" = "true" ]; then LOGIN_OPTS="--insecure"; fi
          PUSH_OPTS=""
          if [ "${HELM_OCI_PLAIN_HTTP:-}" = "true" ]; then PUSH_OPTS="--plain-http"; fi
          charts=(paas-artifacts/helm/*.tgz)
          if [ ${#charts[@]} -eq 0 ]; then
            echo "[helm-oci] Aucun chart .tgz à publier."
            exit 0
          fi
          echo "${HARBOR_PASSWORD}" | helm registry login ${LOGIN_OPTS} "${REG_HOST}" -u "${HARBOR_USERNAME}" --password-stdin || exit 1
          for f in "${charts[@]}"; do
            echo "[helm-oci] helm push $f ${HELM_OCI_REF}"
            helm push ${PUSH_OPTS} "$f" "${HELM_OCI_REF}" || exit 1
          done
        '''
      }
      paasStepOk(11, 'helm_oci', 'Helm OCI push stage finished (charts optional)')
    }
  }

  stage("Step 12 — GitOps (Argo CD) & archivage Jenkins") {
    println "*** BEGIN : GitOps / Argo CD (délégué au PaaS) — aligné Jenkinsfile.paas-deploy.full §12–13 ***"
    println "[argocd] Applications Argo CD et sync : délégués au contrôle PaaS après succès Jenkins ; ce build expose PAAS_ARTIFACT_IMAGE pour le suivi déploiement."
    println "[argocd-helm] Chart OCI (Harbor) : quand l'Application référence oci://…, Argo réconcilie avec la version publiée (credentials côté cluster, pas Jenkins)."
    println "*** END : GitOps / Argo CD ***"
    println "*** BEGIN : 14. Archivage des artefacts Jenkins ***"
    archiveArtifacts artifacts: "sca/**,paas-artifacts/**", allowEmptyArchive: true, onlyIfSuccessful: false
    println "[artifacts] Archives locales (Jenkins) : SCA, ZAP, charts Helm, métadonnées ; Artifactory reste optionnel (Step 8)."
    println "IMAGE_NAME=${imageName} PROJECT_ID=${projectId} BUILD_NUMBER=${env.BUILD_NUMBER}"
    paasStepOk(12, 'archive', 'Jenkins archived sca/** and paas-artifacts/**; GitOps+Argo sync runs in PaaS after build')
    def buildResult = currentBuild.currentResult ?: 'SUCCESS'
    def promoteImage = harborClusterPullImageRef(artifactImage ?: '')
    if (promoteImage && promoteImage != artifactImage) {
      println "[paas] PAAS_BUILD_COMPLETE uses cluster-pull image ${promoteImage} (push ref ${artifactImage})"
    }
    println "PAAS_BUILD_COMPLETE result=${buildResult} image=${promoteImage ?: artifactImage} project=${projectId} build=${env.BUILD_NUMBER}"
    println "*** END : 14. Archivage des artefacts Jenkins ***"
  }

