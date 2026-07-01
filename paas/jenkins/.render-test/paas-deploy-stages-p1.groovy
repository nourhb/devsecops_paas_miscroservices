// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626
def runPaasDeploySteps1_2() {
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
}
def runPaasDeployStep3() {
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
            NM_SNAP_MAX_MB="${JENKINS_NPM_SNAPSHOT_MAX_MB:-800}"
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
      ensurePythonTool()
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
      ensurePythonTool()
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
}
