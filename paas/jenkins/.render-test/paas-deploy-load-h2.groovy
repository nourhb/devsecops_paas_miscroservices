// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626
def normalizeCosignPrivateKeyPem(String raw) {
  if (!raw?.trim()) {
    return ""
  }
  def pem = raw.trim()
  if (pem.startsWith('"') && pem.endsWith('"')) {
    pem = pem.substring(1, pem.length() - 1)
  }
  if (pem.contains('\\n')) {
    pem = pem.replaceAll(/\\n/, '\n')
  }
  pem = pem.replaceAll(/\r\n/, '\n').replaceAll(/\r/, '\n').trim()
  return pem
}

def ensureCosignTool() {
  def labBin = "/var/jenkins_home/bin/cosign"
  if (sh(script: "test -x '${labBin}'", returnStatus: true) == 0) {
    return labBin
  }
  if (commandExists("cosign")) {
    return "cosign"
  }
  println "[cosign] cosign absent du PATH ; installation locale dans le workspace."
  sh '''
    set -eu
    mkdir -p .paas-tools/cosign
    CC="$PWD/.paas-tools/cosign/cosign"
    if [ ! -x "$CC" ]; then
      echo "[tooling] downloading cosign binary…"
      (
        _n=0
        while true; do
          sleep 15
          _n=$((_n + 1))
          echo "[tooling] cosign download still running (${_n}×15s) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        done
      ) &
      HB_PID=$!
      trap 'kill "$HB_PID" 2>/dev/null || true' EXIT
      curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 900 \
        -o .paas-tools/cosign/cosign \
        "https://github.com/sigstore/cosign/releases/download/v2.4.0/cosign-linux-amd64"
      kill "$HB_PID" 2>/dev/null || true
      trap - EXIT
      chmod +x .paas-tools/cosign/cosign
    fi
  '''
  return "${pwd()}/.paas-tools/cosign/cosign"
}

def dockerfileForDetectedProject(String df) {
  if (fileExists(df)) {
    if (fileExists('package.json') && !dockerfileHasProductionBuild(df)) {
      println "[image] ${df} has no production build step — using PaaS-generated Dockerfile (NEXT_PUBLIC_* require next build with project env)"
    } else {
      return df
    }
  }
  def appRoot = detectAppRoot()
  if (fileExists("${appRoot}/package.json")) {
    writeFile file: "Dockerfile", text: '''FROM mirror.gcr.io/library/node:20-bookworm-slim
WORKDIR /app
COPY . .
RUN if [ -f package.json ]; then \\
      npm config set audit false && \\
      npm config set fund false && \\
      npm config set fetch-retries 5 && \\
      npm config set fetch-retry-factor 2 && \\
      npm config set fetch-retry-mintimeout 20000 && \\
      npm config set fetch-retry-maxtimeout 120000 && \\
      npm config set fetch-timeout 1800000 && \\
      npm config set maxsockets 1 && \\
      if [ -f package-lock.json ]; then npm install --no-audit --no-fund --prefer-offline || npm install --no-audit --no-fund; else npm install --no-audit --no-fund --prefer-offline || npm install --no-audit --no-fund; fi && \\
      if node -e "const p=require('./package.json');const d={...p.dependencies||{},...p.devDependencies||{}};process.exit(d.next?0:1)"; then npx next build; \\
      elif node -e "const p=require('./package.json'); const s=p.scripts||{}; process.exit(s['build:ci']?0:1)"; then npm run build:ci; \\
      elif node -e "const p=require('./package.json'); process.exit(p.scripts&&p.scripts.build?0:1)"; then npm run build; fi; \\
    fi
ENV HOSTNAME=0.0.0.0 PORT=3000
EXPOSE 3000
CMD ["sh", "-c", "if [ -f dist/main.js ]; then exec node dist/main.js; elif [ -f server.js ]; then exec node server.js; elif [ -d dist ] && [ -f dist/index.html ]; then exec npx --yes serve@14 -s dist -l 3000; elif [ -d build ] && [ -f build/index.html ]; then exec npx --yes serve@14 -s build -l 3000; elif [ -f package.json ]; then exec npm start; else exec node server.js; fi"]
'''
    return "Dockerfile"
  }
  if (fileExists("${appRoot}/requirements.txt") || fileExists("${appRoot}/pyproject.toml")
      || fileExists("requirements.txt") || fileExists("pyproject.toml")) {
    writeFile file: "Dockerfile", text: '''FROM mirror.gcr.io/library/python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1 PIP_NO_CACHE_DIR=1
COPY . .
RUN pip install --upgrade pip setuptools wheel \\
  && if [ -f requirements.txt ]; then pip install -r requirements.txt; \\
  elif [ -f pyproject.toml ]; then pip install .; \\
  else pip install pip; fi
EXPOSE 8000
CMD ["sh", "-c", "if [ -f manage.py ]; then exec python manage.py runserver 0.0.0.0:8000; elif python -c 'import uvicorn' 2>/dev/null && [ -f main.py ]; then exec uvicorn main:app --host 0.0.0.0 --port 8000; elif [ -f app.py ]; then exec python app.py; else exec python3 -m http.server 8000; fi"]
'''
    return "Dockerfile"
  }
  if (fileExists("pom.xml")) {
    writeFile file: "Dockerfile", text: '''FROM mirror.gcr.io/library/maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml ./
COPY src ./src
RUN mvn -q -DskipTests package
FROM mirror.gcr.io/library/eclipse-temurin:17-jre-jammy
WORKDIR /app
COPY --from=build /app/target/*.jar /app/app.jar
EXPOSE 8080
CMD ["java", "-jar", "/app/app.jar"]
'''
    return "Dockerfile"
  }
  if (fileExists("build.gradle") || fileExists("build.gradle.kts")) {
    writeFile file: "Dockerfile", text: '''FROM mirror.gcr.io/library/eclipse-temurin:17-jdk-jammy AS build
WORKDIR /app
COPY . .
RUN if [ -f gradlew ]; then chmod +x gradlew && ./gradlew build -x test; else gradle build -x test; fi
FROM mirror.gcr.io/library/eclipse-temurin:17-jre-jammy
WORKDIR /app
RUN apt-get update && apt-get install -y findutils && rm -rf /var/lib/apt/lists/*
COPY --from=build /app /app
RUN cp "$(find /app -name '*.jar' | grep -v plain | head -1)" /app/app.jar
EXPOSE 8080
CMD ["java", "-jar", "/app/app.jar"]
'''
    return "Dockerfile"
  }
  if (fileExists("index.html")) {
    writeFile file: "Dockerfile", text: '''FROM mirror.gcr.io/library/nginx:stable-alpine
COPY . /usr/share/nginx/html
EXPOSE 80
CMD ["nginx", "-g", "daemon off;"]
'''
    return "Dockerfile"
  }
  return ""
}

def detectAppRoot() {
  if (fileExists('package.json')) {
    return '.'
  }
  for (def dir in ['server', 'frontend', 'client', 'app', 'web', 'backend', 'api', 'apps/web', 'apps/client']) {
    if (fileExists("${dir}/package.json")) {
      return dir
    }
  }
  if (!fileExists('package.json')) {
    for (def dir in ['server', 'backend', 'api', 'app']) {
      if (fileExists("${dir}/requirements.txt") || fileExists("${dir}/pyproject.toml")) {
        return dir
      }
    }
  }
  return '.'
}

def normalizeOciImageReference(String imageRef) {
  return (imageRef ?: '').trim().toLowerCase()
}

def sanitizeDeployImageName(String name) {
  def value = (name ?: 'app').toLowerCase().replaceAll(/[^a-z0-9._-]/, '-').replaceAll(/-+/, '-')
  value = value.replaceAll(/^-|-$/, '')
  return value ?: 'app'
}

def registryHostFor(String imageRef) {
  def first = imageRef.tokenize("/")[0]
  if (!first.contains(".") && !first.contains(":") && first != "localhost") {
    return "index.docker.io"
  }
  return first
}

def coerceHarborHostForCosign(String host) {
  if (!host?.trim()) {
    return ''
  }
  def h = host.trim().replaceFirst('^https?://', '').replaceAll('/+$', '')
  def m = (h =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})(?::(\d+))?$/)
  if (m.matches()) {
    def ip = m.group(1)
    def port = m.group(2) ?: ''
    return port ? "harbor.${ip}.nip.io:${port}" : "harbor.${ip}.nip.io"
  }
  return h
}

def harborIpRegistryHostFromNipio(String host) {
  if (!host?.trim()) {
    return host ?: ''
  }
  def h = host.trim()
  def m = (h =~ /^harbor\.(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\.nip\.io(?::(\d+))?$/)
  if (m.matches()) {
    def ip = m.group(1)
    def port = m.group(2) ?: ''
    return port ? "${ip}:${port}" : ip
  }
  return h
}

def imageRefHarborIp(String imageRef) {
  def ref = (imageRef ?: '').trim()
  if (!ref) {
    return ref
  }
  def slash = ref.indexOf('/')
  if (slash <= 0) {
    return ref
  }
  def host = ref.substring(0, slash)
  def path = ref.substring(slash)
  return "${harborIpRegistryHostFromNipio(host)}${path}"
}

def paasHarborCranePushShellHelpers(String craneBin, String imageRef, String imageRefIp, String craneInsecure) {
  def regHost = imageRef.tokenize('/')[0]
  def ipHost = imageRefIp.tokenize('/')[0]
  return """
    harbor_nipio_to_ip_ref() {
      local ref="\$1"
      case "\$ref" in
        harbor.*.nip.io:*/*|harbor.*.nip.io/*)
          local host="\${ref%%/*}"
          local rest="\${ref#*/}"
          local nip_host port ip
          nip_host="\${host%%:*}"
          port="\${host#*:}"
          if [ "\${port}" = "\${nip_host}" ]; then port=""; fi
          ip="\$(printf '%s' "\${nip_host}" | sed -nE 's/^harbor\\.([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)\\.nip\\.io\$/\\1/p')"
          [ -n "\${ip}" ] || return 1
          if [ -n "\${port}" ]; then printf '%s/%s' "\${ip}:\${port}" "\${rest}"
          else printf '%s/%s' "\${ip}" "\${rest}"; fi
          return 0
          ;;
      esac
      return 1
    }
    paas_crane_harbor_login() {
      local _nip="\${HARBOR_REGISTRY:-${regHost}}"
      local _ip="\$(harbor_nipio_to_ip_ref "\${_nip}/x" 2>/dev/null | cut -d/ -f1 || true)"
      [ -z "\${_ip}" ] && _ip="${ipHost}"
      local _u="\${HARBOR_USERNAME:-admin}"
      local _p="\${HARBOR_PASSWORD:-}"
      [ -n "\${_p}" ] || { echo "[image] ERROR: HARBOR_PASSWORD empty"; return 1; }
      export DOCKER_CONFIG="\${JENKINS_HOME:-/var/jenkins_home}/.docker-paas-crane"
      mkdir -p "\${DOCKER_CONFIG}"
      for _r in "\${_ip}" "\${_nip}"; do
        [ -z "\${_r}" ] && continue
        echo "[image] crane re-login \${_r} before push (password-stdin)"
        printf '%s' "\${_p}" | "${craneBin}" ${craneInsecure} auth login "\${_r}" -u "\${_u}" --password-stdin --insecure
      done
    }
    paas_harbor_ensure_project_and_token() {
      local _user="\${HARBOR_USERNAME:-admin}"
      local _pass="\${HARBOR_PASSWORD:-}"
      local _nip="\${HARBOR_REGISTRY:-${regHost}}"
      local _ip="\$(harbor_nipio_to_ip_ref "\${_nip}/x" 2>/dev/null | cut -d/ -f1 || true)"
      [ -z "\${_ip}" ] && _ip="${ipHost}"
      local _repo="\${_push_ref_ip#*/}"
      _repo="\${_repo%%:*}"
      local _proj="\${_repo%%/*}"
      [ -n "\${_user}" ] && [ -n "\${_pass}" ] || { echo "[image] ERROR: Harbor creds empty"; return 1; }
      for _api in "http://\${_ip}" "http://\${_nip}"; do
        [ -z "\${_api#http://}" ] && continue
        _hc="\$(curl -sS -o /dev/null -w '%{http_code}' -u "\${_user}:\${_pass}" \\
          "\${_api}/api/v2.0/projects/\${_proj}" 2>/dev/null || echo 000)"
        if [ "\${_hc}" != "200" ]; then
          echo "[image] Harbor ensure project \${_proj} (GET HTTP \${_hc}) via \${_api}"
          curl -sS -u "\${_user}:\${_pass}" -X POST "\${_api}/api/v2.0/projects" \\
            -H 'Content-Type: application/json' \\
            -d "{\\"project_name\\":\\"\${_proj}\\",\\"metadata\\":{\\"public\\":\\"true\\"}}" >/dev/null 2>&1 || true
          curl -sS -u "\${_user}:\${_pass}" -X POST "\${_api}/api/v2.0/projects" \\
            -H 'Content-Type: application/json' \\
            -d "{\\"project_name\\":\\"\${_proj}\\",\\"public\\":true}" >/dev/null 2>&1 || true
        fi
        _resp="\$(curl -sS -u "\${_user}:\${_pass}" \\
          "\${_api}/service/token?service=harbor-registry&scope=repository:\${_repo}:pull,push" 2>/dev/null || true)"
        if echo "\${_resp}" | grep -q '"token"[[:space:]]*:[[:space:]]*"'; then
          if echo "\${_resp}" | grep -qE '"actions"[[:space:]]*:[[:space:]]*\\[\\s*\\]'; then
            echo "[image] ERROR: Harbor JWT has no push scope — bash paas/scripts/lab.sh fix-harbor-push"
            return 1
          fi
          echo "[image] Harbor token endpoint OK (\${_api} repo=\${_repo})"
          return 0
        fi
      done
      echo "[image] WARN: Harbor precheck could not read token for \${_repo}; continuing to real crane push"
      return 0
    }
"""
}

def harborClusterPullImageRef(String imageRef) {
  def ref = (imageRef ?: '').trim()
  if (!ref) {
    return ref
  }
  def digestAt = ref.indexOf('@sha256:')
  if (digestAt > 0) {
    def repoPart = ref.substring(0, digestAt)
    def digest = ref.substring(digestAt)
    def slash = repoPart.indexOf('/')
    if (slash > 0) {
      def host = repoPart.substring(0, slash)
      def path = repoPart.substring(slash)
      return "${harborIpRegistryHostFromNipio(host)}${path}${digest}".toLowerCase()
    }
  }
  def slash = ref.indexOf('/')
  def lastColon = ref.lastIndexOf(':')
  if (slash > 0 && lastColon > slash && lastColon < ref.length() - 1) {
    def repoPart = ref.substring(0, lastColon)
    def tag = ref.substring(lastColon)
    def repoSlash = repoPart.indexOf('/')
    def host = repoPart.substring(0, repoSlash)
    def path = repoPart.substring(repoSlash)
    return "${harborIpRegistryHostFromNipio(host)}${path}${tag}".toLowerCase()
  }
  if (slash > 0) {
    def host = ref.substring(0, slash)
    def path = ref.substring(slash)
    return "${harborIpRegistryHostFromNipio(host)}${path}".toLowerCase()
  }
  return ref.toLowerCase()
}

def coerceImageRefRegistryHost(String imageRef) {
  def ref = (imageRef ?: '').trim()
  if (!ref) {
    return ref
  }
  def slash = ref.indexOf('/')
  if (slash < 0) {
    return ref.toLowerCase()
  }
  def host = ref.substring(0, slash)
  def rest = ref.substring(slash + 1)
  def coerced = coerceHarborHostForCosign(host)
  if (coerced == host) {
    return ref.toLowerCase()
  }
  return "${coerced}/${rest}".toLowerCase()
}

def normalizeRegistryHost(String reg) {
  if (!reg?.trim()) {
    return ""
  }
  return coerceHarborHostForCosign(reg.trim().replaceFirst('^https?://', '').replaceAll('/+$', '').split('/')[0])
}

def harborForceNodePortPush() {
  def v = (params.HARBOR_FORCE_NODEPORT_PUSH?.trim() ?: env.HARBOR_FORCE_NODEPORT_PUSH ?: 'true')
  return v.equalsIgnoreCase('true')
}

def resolveHarborPushImageRef(String imageRef) {
  def coerced = coerceImageRefRegistryHost(imageRef)
  if (harborForceNodePortPush()) {
    return coerced
  }
  def pushRaw = (params.HARBOR_REGISTRY_PUSH?.trim() ?: env.HARBOR_REGISTRY_PUSH?.trim() ?: "")
  def pushReg = normalizeRegistryHost(pushRaw)
  def external = normalizeRegistryHost(params.HARBOR_REGISTRY?.trim() ?: env.HARBOR_REGISTRY ?: "")
  if (!external || !pushReg || external == pushReg || !coerced?.trim()) {
    return coerced
  }
  def ref = coerced.trim()
  if (ref.startsWith("${external}/")) {
    return ref.replaceFirst(external, pushReg)
  }
  return coerced
}

def isDockerHubStyleImageRef(String imageRef) {
  def parts = imageRef?.trim()?.tokenize('/') ?: []
  if (parts.size() != 2) {
    return false
  }
  def host = parts[0]
  return !host.contains('.') && !host.contains(':') && host != 'localhost'
}

def resolveImageNameForHarbor(String imageRef) {
  def harborHost = normalizeRegistryHost(params.HARBOR_REGISTRY?.trim() ?: env.HARBOR_REGISTRY ?: "")
  if (!harborHost || !env.HARBOR_USERNAME?.trim() || !env.HARBOR_PASSWORD?.trim()) {
    return imageRef
  }
  def normalized = imageRef?.trim() ?: ""
  if (!normalized) {
    return imageRef
  }
  if (normalized.startsWith("${harborHost}/")) {
    return normalized
  }
  if (!isDockerHubStyleImageRef(normalized)) {
    return normalized
  }
  def harborProject = (params.HELM_OCI_PROJECT?.trim() ?: env.HELM_OCI_PROJECT ?: 'paas').trim().toLowerCase()
  def appName = normalized.tokenize('/')[1]?.toLowerCase() ?: sanitizeDeployImageName(normalized)
  def resolved = normalizeOciImageReference("${harborHost}/${harborProject}/${appName}")
  println "[image] Rewrote Docker Hub–style ref ${normalized} → Harbor ${resolved}"
  return resolved
}

def paasShellKeepaliveHelper() {
  return '''    JENKINS_SH_KEEPALIVE=true
    JENKINS_SH_KEEPALIVE_SEC="${JENKINS_SH_KEEPALIVE_SEC:-20}"
    run_with_keepalive() {
      if [ "${JENKINS_SH_KEEPALIVE:-true}" != "true" ]; then
        "$@"
        return $?
      fi
      _rwk_sec="${JENKINS_SH_KEEPALIVE_SEC:-20}"
      echo "[image] (keepalive) starting $* at $(date -u +%Y-%m-%dT%H:%M:%SZ) — heartbeat every ${_rwk_sec}s (foreground cmd; JENKINS-48300)"
      ( while true; do
          sleep "${_rwk_sec}"
          echo "[image] (keepalive) $* still running $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        done ) &
      _rwk_hb=$!
      "$@"
      _rwk_rc=$?
      kill "${_rwk_hb}" 2>/dev/null || true
      wait "${_rwk_hb}" 2>/dev/null || true
      return "${_rwk_rc}"
    }
'''
}

def dockerlessPythonCranePush(String craneBin, String imageRef, String artifactImageRef, String craneInsecure, String appRoot) {
  def imageRefIp = imageRef
  def slash = imageRef.indexOf('/')
  if (slash > 0) {
    def host = imageRef.substring(0, slash)
    def path = imageRef.substring(slash)
    imageRefIp = "${harborIpRegistryHostFromNipio(host)}${path}"
  }
  println "[image] Step 6 — python crane path (gunicorn>=22 / flask; port 8000; marker=python-gunicorn22-20260610)"
  sh """
    set -eu
    cd '${appRoot}'
    mkdir -p paas-artifacts
    VENDOR_DIR="_paas_vendor"
    rm -rf "\${VENDOR_DIR}"
    if command -v python3 >/dev/null 2>&1 && [ -f requirements.txt ]; then
      echo "[image] pre-vendor python deps (faster pod start)"
      python3 -m pip install -q -t "\${VENDOR_DIR}" -r requirements.txt 2>/dev/null || true
      python3 -m pip install -q -t "\${VENDOR_DIR}" 'gunicorn>=22' 'flask>=2' 2>/dev/null || true
    fi
    cat > start-paas-python.sh <<'PAAS_PY'
#!/bin/sh
set -eu
cd /app || exit 1
export PYTHONUNBUFFERED=1
export PORT=\${PORT:-8000}
export PYTHONPATH="/app/_paas_vendor:\${PYTHONPATH:-}"
install_deps() {
  pip install --quiet --upgrade pip setuptools wheel 2>/dev/null || true
  if [ -f requirements.txt ]; then
    pip install --quiet -r requirements.txt
  fi
  pip install --quiet 'gunicorn>=22' 'flask>=2' 2>/dev/null || true
}
if ! python3 -c "import flask" 2>/dev/null && ! python3 -c "import django" 2>/dev/null; then
  install_deps
fi
run_gunicorn() {
  _target="\${1:-main:app}"
  if ! python3 -c "import gunicorn" 2>/dev/null; then
    install_deps
  fi
  if [ -f gunicorn.conf.py ]; then
    exec python3 -m gunicorn -b "0.0.0.0:\${PORT}" -c gunicorn.conf.py "\${_target}"
  fi
  exec python3 -m gunicorn -b "0.0.0.0:\${PORT}" "\${_target}"
}
if [ -f main.py ] && python3 -c "import main" 2>/dev/null; then
  run_gunicorn main:app
fi
if python3 -c "import uvicorn" 2>/dev/null && [ -f main.py ]; then
  exec python3 -m uvicorn main:app --host 0.0.0.0 --port "\${PORT}"
fi
if [ -f manage.py ]; then
  exec python manage.py runserver 0.0.0.0:"\${PORT}"
fi
if [ -f main.py ]; then
  exec python main.py
fi
if [ -f app.py ]; then
  exec python app.py
fi
exec python3 -m http.server "\${PORT}"
PAAS_PY
    chmod +x start-paas-python.sh
    tar --exclude='./.git' --exclude='./paas-artifacts' --exclude='./.paas-tools' \\
      --exclude='./node_modules' --exclude='./__pycache__' \\
      --transform='s#^\\./#app/#' -cf paas-artifacts/app-layer.tar .
    echo "[image] python crane append → ${imageRefIp} (IP-first; nip.io alias ${imageRef})"
    export DOCKER_CONFIG="\${JENKINS_HOME:-/var/jenkins_home}/.docker-paas-crane"
    mkdir -p "\${DOCKER_CONFIG}"
    _harbor_ip="${imageRefIp.tokenize('/')[0]}"
    _harbor_nip="${imageRef.tokenize('/')[0]}"
    _harbor_pass="\${HARBOR_PASSWORD:-}"
    for _r in "\${_harbor_ip}" "\${_harbor_nip}"; do
      [ -z "\${_r}" ] && continue
      printf '%s' "\${_harbor_pass}" | "${craneBin}" ${craneInsecure} auth login "\${_r}" -u "\${HARBOR_USERNAME:-admin}" --password-stdin --insecure || true
    done
    _crane_ok=0
    for _py_base in \\
      mirror.gcr.io/library/python:3.11-slim \\
      mirror.gcr.io/library/python:3.12-slim \\
      mirror.gcr.io/library/python:3.12-slim-bookworm; do
      echo "[image] python crane append try base=\${_py_base} → ${imageRefIp}"
      if "${craneBin}" ${craneInsecure} append \\
        -b "\${_py_base}" \\
        -f paas-artifacts/app-layer.tar \\
        -t "${imageRefIp}"; then
        _crane_ok=1
        break
      fi
    done
    if [ "\${_crane_ok}" != 1 ]; then
      echo "[image] ERROR: python crane append failed — run: bash paas/scripts/lab.sh fix-harbor-push"
      exit 1
    fi
    if [ "${imageRefIp}" != "${imageRef}" ]; then
      "${craneBin}" ${craneInsecure} tag "${imageRefIp}" "${imageRef}" || true
    fi
    "${craneBin}" ${craneInsecure} mutate "${imageRefIp}" \\
      -t "${imageRef}" \\
      --workdir=/app \\
      --entrypoint=/app/start-paas-python.sh \\
      --exposed-ports=8000/tcp
    ARTIFACT_REF="${artifactImageRef}"
    if [ -n "\${ARTIFACT_REF}" ] && [ "\${ARTIFACT_REF}" != "${imageRef}" ]; then
      "${craneBin}" ${craneInsecure} copy "${imageRef}" "\${ARTIFACT_REF}" || true
    fi
    mkdir -p paas-artifacts
    REF="\${ARTIFACT_REF:-${artifactImageRef}}"
    DIGEST_REF="\$(${craneBin} ${craneInsecure} digest \${REF} 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ -n "\${DIGEST_REF}" ]; then
      case "\${DIGEST_REF}" in
        sha256:*)
          REPO="\${REF%:*}"
          DIGEST_REF="\${REPO}@\${DIGEST_REF}"
          ;;
      esac
      echo "\${DIGEST_REF}" > paas-artifacts/image-digest-ref.txt
      echo "PAAS_IMAGE_DIGEST=\${DIGEST_REF}"
      echo "PAAS_IMAGE_DIGEST=\${DIGEST_REF}" >> paas-artifacts/cosign-meta.txt
    fi
  """
}

def dockerlessNginxCranePush(String craneBin, String imageRef, String artifactImageRef, String craneInsecure, String appRoot, String framework) {
  println '[image] marker=nginx-conf-writefile-20260611 (writeFile default.conf — no Groovy $uri in sh """)'
  def legacyAngular = isLegacyAngularProject(appRoot)
  if (legacyAngular) {
    println '[paas-jenkinsfile] marker=angular-legacy-ng-build-20260613 (Node16 + ng build --progress=false; 4G heap; Step6 timeout bump)'
  }
  def nodeVer = resolveNodeVersion(appRoot)
  println "[image] Step 6 — nginx static crane path (angular/spa dist → port 80; Node ${nodeVer})"
  ensureNodeTool(nodeVer)
  def heapMb = legacyAngular ? '4096' : '2048'
  withEnv(["PAAS_FRAMEWORK=${framework}", "PAAS_LEGACY_ANGULAR=${legacyAngular ? 'true' : 'false'}"]) {
    sh """
      set -eu
      cd '${appRoot}'
      export NODE_OPTIONS="\${NODE_OPTIONS:-} --max-old-space-size=\${JENKINS_NODE_MAX_OLD_SPACE_MB:-${heapMb}}"
${paasShellKeepaliveHelper()}
${paasOpensslLegacyShellSnippet()}
      echo "[image] nginx build using node \$(node -v 2>/dev/null || echo missing)"
      if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
        if [ ! -d node_modules ] || { [ -f package.json ] && grep -q '@angular/core' package.json 2>/dev/null && [ ! -d node_modules/@angular ]; }; then
          echo "[image] nginx path — npm install before ng build"
          if [ -f package-lock.json ]; then
            run_with_keepalive npm ci --no-audit --no-fund --prefer-offline || run_with_keepalive npm install --no-audit --no-fund
          else
            run_with_keepalive npm install --no-audit --no-fund
          fi
        fi
        if [ ! -d dist ] && [ ! -d build ]; then
          echo "[image] nginx path — npm build before static layer"
          if [ -f package.json ] && grep -q '@angular/core' package.json 2>/dev/null && [ -x node_modules/.bin/ng ]; then
            echo "[image] legacy/modern Angular — ng build --progress=false (ivy compile may take several minutes)"
            run_with_keepalive ./node_modules/.bin/ng build --progress=false
          elif node -e "const s=require('./package.json').scripts||{};process.exit(s['build:ci']?0:1)" 2>/dev/null; then
            run_with_keepalive npm run build:ci
          elif node -e "const p=require('./package.json');process.exit(p.scripts&&p.scripts.build?0:1)" 2>/dev/null; then
            run_with_keepalive npm run build
          fi
        fi
      fi
    """
  }
  sh """
    set -eu
    cd '${appRoot}'
    mkdir -p paas-artifacts
    STATIC_ROOT=""
    for d in dist build public; do
      if [ -f "\$d/index.html" ]; then STATIC_ROOT="\$d"; break; fi
      if [ -d "\$d" ]; then
        _idx=\$(find "\$d" -mindepth 1 -maxdepth 4 -name index.html 2>/dev/null | head -1)
        if [ -n "\$_idx" ]; then STATIC_ROOT=\$(dirname "\$_idx"); break; fi
      fi
    done
    if [ -z "\$STATIC_ROOT" ]; then
      echo "[image] ERROR: nginx runtime but no dist/build with index.html"
      exit 1
    fi
    if [ -f package.json ] && grep -q '@angular/core' package.json 2>/dev/null; then
      if ! find "\$STATIC_ROOT" -name '*.js' -size +512c 2>/dev/null | head -1 | grep -q .; then
        echo "[image] ERROR: angular build produced no JS bundles under \$STATIC_ROOT — fix ng build / source errors"
        exit 1
      fi
    fi
    echo "[image] nginx static root: \$STATIC_ROOT"
    rm -rf paas-artifacts/_nginx_html paas-artifacts/_nginx_conf
    mkdir -p paas-artifacts/_nginx_html
    cp -a "\${STATIC_ROOT}/." paas-artifacts/_nginx_html/
    tar -C paas-artifacts/_nginx_html --transform='s#^#usr/share/nginx/html/#' -cf paas-artifacts/app-layer.tar .
    mkdir -p paas-artifacts/_nginx_conf/conf.d
  """
  writeNginxPaasDefaultConf(appRoot)
  def imageRefIp = imageRefHarborIp(imageRef)
  println '[paas-jenkinsfile] marker=nginx-crane-ip-first-20260701 (IP push + nip.io mutate — same Harbor path as Next.js)'
  sh """
    set -eu
    cd '${appRoot}'
    tar -C paas-artifacts/_nginx_conf --transform='s#^#etc/nginx/#' -rf paas-artifacts/app-layer.tar .
${paasHarborCranePushShellHelpers(craneBin, imageRef, imageRefIp, craneInsecure)}
    _crane_max="\${JENKINS_CRANE_PUSH_RETRIES:-3}"
    if [ "\${_crane_max}" -lt 2 ] 2>/dev/null; then _crane_max=2; fi
    _crane_attempt=1
    _crane_rc=1
    _push_ref_ip="${imageRefIp}"
    paas_harbor_ensure_project_and_token || exit 1
    echo "[image] primary push ref (IP): ${imageRefIp} ; alias ref: ${imageRef}"
    while [ "\${_crane_attempt}" -le "\${_crane_max}" ]; do
      paas_crane_harbor_login || true
      _push_ref="\${_push_ref_ip}"
      echo "[image] nginx crane append attempt \${_crane_attempt}/\${_crane_max} → \${_push_ref}"
      "${craneBin}" ${craneInsecure} append \\
        -b mirror.gcr.io/library/nginx:stable-alpine \\
        -f paas-artifacts/app-layer.tar \\
        -t "\${_push_ref}" && _crane_rc=0 || _crane_rc=\$?
      if [ "\${_crane_rc}" = "0" ]; then
        if [ "\${_push_ref_ip}" != "${imageRef}" ]; then
          echo "[image] pushed via IP ref — tagging nip.io alias ${imageRef}"
          "${craneBin}" ${craneInsecure} tag "\${_push_ref_ip}" "${imageRef}" || true
        fi
        break
      fi
      echo "[image] WARN: nginx crane append failed (rc=\${_crane_rc}); try: bash paas/scripts/lab.sh harbor"
      if [ "\${_crane_attempt}" -ge "\${_crane_max}" ]; then
        exit "\${_crane_rc}"
      fi
      _crane_attempt=\$((_crane_attempt + 1))
      sleep 45
    done
    _mutate_max="\${JENKINS_CRANE_PUSH_RETRIES:-3}"
    _mutate_attempt=1
    _mutate_rc=1
    while [ "\${_mutate_attempt}" -le "\${_mutate_max}" ]; do
      echo "[image] nginx crane mutate attempt \${_mutate_attempt}/\${_mutate_max} → ${imageRef}"
      "${craneBin}" ${craneInsecure} mutate "${imageRef}" \\
        -t "${imageRef}" \\
        --cmd=nginx \\
        --cmd=-g \\
        --cmd='daemon off;' \\
        --exposed-ports=80/tcp && _mutate_rc=0 || _mutate_rc=\$?
      if [ "\${_mutate_rc}" = "0" ]; then
        break
      fi
      if [ "\${_mutate_attempt}" -ge "\${_mutate_max}" ]; then
        exit "\${_mutate_rc}"
      fi
      _mutate_attempt=\$((_mutate_attempt + 1))
      sleep 30
    done
    ARTIFACT_REF="${artifactImageRef}"
    if [ -n "\${ARTIFACT_REF}" ] && [ "\${ARTIFACT_REF}" != "${imageRef}" ]; then
      "${craneBin}" ${craneInsecure} copy "${imageRef}" "\${ARTIFACT_REF}" || true
    fi
    mkdir -p paas-artifacts
    REF="\${ARTIFACT_REF:-${artifactImageRef}}"
    DIGEST_REF="\$(${craneBin} ${craneInsecure} digest \${REF} 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ -n "\${DIGEST_REF}" ]; then
      case "\${DIGEST_REF}" in
        sha256:*)
          REPO="\${REF%:*}"
          DIGEST_REF="\${REPO}@\${DIGEST_REF}"
          ;;
      esac
      echo "\${DIGEST_REF}" > paas-artifacts/image-digest-ref.txt
      echo "PAAS_IMAGE_DIGEST=\${DIGEST_REF}"
      echo "PAAS_IMAGE_DIGEST=\${DIGEST_REF}" >> paas-artifacts/cosign-meta.txt
    fi
  """
}

// cps-split-dockerless-6abc-20260620
def dockerlessImagePushCraneNode6a(String appRoot) {
  println "[image] Step 6a — npm deps (separate durable-task sh; survives Jenkins restart better than one 40+ min script)"
  sh """
    set -eu
    cd '${appRoot}'
    export NODE_OPTIONS="\${NODE_OPTIONS:-} --max-old-space-size=\${JENKINS_NODE_MAX_OLD_SPACE_MB:-2048}"
${paasShellKeepaliveHelper()}
    if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
      if [ ! -f .next/BUILD_ID ] && [ ! -f .next/standalone/server.js ] && [ ! -d node_modules/next ]; then
        echo "[image] crane-next16-202605-j48300: npm ci (prefer Step 3 with JENKINS_PAAS_FAST_PIPELINE=false)"
        npm config set progress true 2>/dev/null || true
        npm config set fetch-timeout 1800000 2>/dev/null || true
        NM_SNAP=""
        if [ "\${JENKINS_NPM_SNAPSHOT_NODE_MODULES:-true}" != "false" ] && [ -n "\${JENKINS_HOME:-}" ] && [ -n "\${PROJECT_ID:-}" ] && [ -f package-lock.json ]; then
          LOCK_HASH=\$(sha256sum package-lock.json 2>/dev/null | awk '{print \$1}')
          if [ -n "\$LOCK_HASH" ]; then
            NM_SNAP="\${JENKINS_HOME}/.jenkins-paas-cache/nm-snap/\${PROJECT_ID}/\${LOCK_HASH}"
          fi
        fi
        _deps_ok=0
        if [ -n "\$NM_SNAP" ] && [ -d "\$NM_SNAP" ] && [ -n "\$(ls -A "\$NM_SNAP" 2>/dev/null)" ]; then
          echo "[image] restore node_modules from snapshot (tar)"
          rm -rf node_modules
          mkdir -p node_modules
          run_with_keepalive bash -c "tar -C \"\${NM_SNAP}\" -cf - . | tar -C node_modules -xf -"
          if run_with_keepalive npm install --no-audit --no-fund --prefer-offline --loglevel info; then
            _deps_ok=1
          else
            echo "[image] snapshot stale; full npm ci"
            rm -rf node_modules
          fi
        fi
        if [ "\${_deps_ok}" != "1" ]; then
          if [ -f package-lock.json ]; then
            run_with_keepalive npm ci --no-audit --no-fund --loglevel info
          else
            run_with_keepalive npm install --no-audit --no-fund --loglevel info
          fi
        fi
        if [ -n "\$NM_SNAP" ] && [ -d node_modules ] && [ "\${_deps_ok}" != "1" ]; then
          mkdir -p "\$(dirname "\$NM_SNAP")"
          rm -rf "\${NM_SNAP}.new" "\$NM_SNAP"
          mkdir -p "\${NM_SNAP}.new"
          echo "[image] saving node_modules snapshot via tar…"
          if run_with_keepalive bash -c 'set -o pipefail; tar -C node_modules -cf - . | tar -C "'"\${NM_SNAP}"'.new" -xf -'; then
            if [ -d "\${NM_SNAP}.new" ] && [ -n "\$(ls -A "\${NM_SNAP}.new" 2>/dev/null)" ]; then
              mv "\${NM_SNAP}.new" "\$NM_SNAP"
              echo "[image] node_modules snapshot saved → \$NM_SNAP"
            else
              echo "[image] WARN: snapshot .new empty after tar — keeping existing cache if any"
              rm -rf "\${NM_SNAP}.new"
            fi
          else
            echo "[image] WARN: snapshot tar failed — continuing build without cache refresh"
            rm -rf "\${NM_SNAP}.new"
          fi
        elif [ "\${_deps_ok}" = "1" ]; then
          echo "[image] node_modules snapshot hit in Step 6a — skip re-save (Step 3 cache still valid)"
        fi
      else
        echo "[image] Step 6a skip — node_modules/next or .next already present"
      fi
    fi
  """

}

def dockerlessImagePushCraneNode6b(String appRoot, String imageStack) {
  println "[image] Step 6b — Next.js production build (separate sh)"
  sh """
    set -eu
    cd '${appRoot}'
    export PAAS_FRAMEWORK='${imageStack}'
    export NODE_OPTIONS="\${NODE_OPTIONS:-} --max-old-space-size=\${JENKINS_NODE_MAX_OLD_SPACE_MB:-2048}"
${paasShellKeepaliveHelper()}
${paasOpensslLegacyShellSnippet()}
${paasForceFreshNextBuildShellSnippet()}
    if [ -f package.json ] && command -v npm >/dev/null 2>&1 && node -e "const p=require('./package.json');const d={...p.dependencies||{},...p.devDependencies||{}};process.exit(d.next?0:1)" 2>/dev/null; then
      if [ ! -f .next/BUILD_ID ] && [ ! -f .next/standalone/server.js ] || [ -n "\${PROJECT_BUILD_ENV_B64:-}" ]; then
        echo "[image] crane-next16-202605-j48300: npx next build"
        NB_FLAGS=""
        if [ "\${JENKINS_NEXT_BUILD_WEBPACK:-false}" = "true" ]; then NB_FLAGS="--webpack"; fi
        _next_hb=""
        if [ "\${JENKINS_NEXT_BUILD_HEARTBEAT:-true}" != "false" ]; then
          _hb_sec="\${JENKINS_NEXT_BUILD_HEARTBEAT_SEC:-20}"
          ( while true; do echo "[image] (next heartbeat) still building… \$(date -u +%Y-%m-%dT%H:%M:%SZ)"; sleep "\${_hb_sec}"; done ) &
          _next_hb=\$!
          trap 'kill "\${_next_hb}" 2>/dev/null || true' EXIT
        fi
${paasSourceBuildEnvShellSnippet()}
        run_with_keepalive npx next build \$NB_FLAGS
        if [ -n "\${_next_hb}" ]; then kill "\${_next_hb}" 2>/dev/null || true; trap - EXIT; fi
      fi
      if [ ! -f .next/BUILD_ID ] && [ ! -f .next/standalone/server.js ]; then
        echo "[image] ERROR: Next.js build still missing .next/BUILD_ID"
        exit 1
      fi
    elif [ -f package.json ] && command -v npm >/dev/null 2>&1 && node -e "const s=require('./package.json').scripts||{};process.exit(s.build||s['build:ci']?0:1)" 2>/dev/null; then
      if [ ! -d dist ] && [ ! -d build ] && [ ! -f .next/BUILD_ID ]; then
        echo "[image] Step 6b — generic npm build (angular/react/vite/express/nest)"
        if node -e "const s=require('./package.json').scripts||{};process.exit(s['build:ci']?0:1)" 2>/dev/null; then
          run_with_keepalive npm run build:ci
        else
          run_with_keepalive npm run build
        fi
      else
        echo "[image] Step 6b skip — dist/build/.next already present"
      fi
    fi
  """

}

def dockerlessImagePushCraneNode6c(String craneBin, String imageRef, String artifactImageRef, String craneInsecure, String appRoot) {
  def imageRefIp = imageRefHarborIp(imageRef)
  println "[image] Step 6c — layer tar + crane append"
  sh """
    set -eu
    cd '${appRoot}'
${paasHarborCranePushShellHelpers(craneBin, imageRef, imageRefIp, craneInsecure)}
    if [ -f package.json ] && command -v npm >/dev/null 2>&1 && [ "\${JENKINS_NPM_PRUNE_BEFORE_CRANE:-true}" != "false" ] && [ ! -d .next/standalone ]; then
      echo "[image] npm prune --omit=dev — shrink root node_modules (skipped when .next/standalone exists)"
      npm prune --omit=dev || echo "[image] WARN: npm prune failed, continuing"
    fi
    mkdir -p paas-artifacts
    cat > start-paas.sh <<'PAAS_START'
#!/bin/sh
set -eu
cd /app || exit 1
export NODE_ENV=\${NODE_ENV:-production}
export HOSTNAME=\${HOSTNAME:-0.0.0.0}
export PORT=\${PORT:-3000}
if [ -f dist/main.js ]; then
  exec node dist/main.js
fi
if [ -f server.js ]; then
  exec node server.js
fi
if [ -f index.js ]; then
  exec node index.js
fi
if [ -d dist ] && [ -f dist/index.html ]; then
  exec npx --yes serve@14 -s dist -l "\${PORT}"
fi
if [ -d build ] && [ -f build/index.html ]; then
  exec npx --yes serve@14 -s build -l "\${PORT}"
fi
if [ -f .next/standalone/server.js ]; then
  exec node .next/standalone/server.js
fi
if [ -d node_modules/next ] && { [ -d .next ] || [ -f .next/BUILD_ID ]; }; then
  exec npx next start -H "\${HOSTNAME}" -p "\${PORT}"
fi
if [ -f package.json ]; then
  exec npm start
fi
exec node server.js
PAAS_START
    chmod +x start-paas.sh
    STL="\${JENKINS_CRANE_STANDALONE_LAYER:-auto}"
    USE_STANDALONE=0
    if [ -d .next/standalone ]; then
      if [ "\$STL" != "false" ] && [ "\$STL" != "0" ] && [ "\$STL" != "no" ]; then
        USE_STANDALONE=1
      fi
    fi
    printf '%s' "\$USE_STANDALONE" > paas-artifacts/_crane_use_standalone
    if [ "\$USE_STANDALONE" = "1" ]; then
      echo "[image] Next.js standalone → minimal crane layer (much smaller/faster than full node_modules). Disable: JENKINS_CRANE_STANDALONE_LAYER=false"
      rm -rf paas-artifacts/_crane_st
      mkdir -p paas-artifacts/_crane_st/.next
      cp -a .next/standalone/. paas-artifacts/_crane_st/
      cp -a .next/static paas-artifacts/_crane_st/.next/static
      if [ -d public ]; then cp -a public paas-artifacts/_crane_st/public; fi
      tar -C paas-artifacts/_crane_st --transform='s#^#app/#' -cf paas-artifacts/app-layer.tar .
      rm -rf paas-artifacts/_crane_st
    else
      if [ -d .next/standalone ]; then
        echo "[image] .next/standalone present but JENKINS_CRANE_STANDALONE_LAYER=\$STL — using full workspace tar (slow)."
      else
        echo "[image] No .next/standalone — full workspace + node_modules in layer (often 10–40+ min upload). Fix: add output: 'standalone' in next.config.js."
      fi
      tar --exclude='./.git' --exclude='./paas-artifacts' --exclude='./.paas-tools' \\
        --exclude='./.next/cache' \\
        --exclude='./node_modules/.cache' \\
        --exclude='./coverage' --exclude='./.eslintcache' \\
        --transform='s#^\\./#app/#' -cf paas-artifacts/app-layer.tar .
    fi
    echo "[image] crane append → registry (this step can take many minutes on slow links)"
    _crane_max="\${JENKINS_CRANE_PUSH_RETRIES:-3}"
    if [ "\${_crane_max}" -lt 2 ] 2>/dev/null; then _crane_max=2; fi
    _crane_attempt=1
    _crane_rc=1
    _push_ref_ip="${imageRefIp}"
    paas_harbor_ensure_project_and_token || exit 1
    echo "[image] primary push ref (IP): ${imageRefIp} ; alias ref: ${imageRef}"
    while [ "\${_crane_attempt}" -le "\${_crane_max}" ]; do
      paas_crane_harbor_login || true
      _push_ref="\${_push_ref_ip}"
      echo "[image] crane append attempt \${_crane_attempt}/\${_crane_max} → \${_push_ref}"
      if [ "\${JENKINS_NEXT_BUILD_HEARTBEAT:-true}" != "false" ]; then
        _hb="\${JENKINS_NEXT_BUILD_HEARTBEAT_SEC:-45}"
        "${craneBin}" ${craneInsecure} append \\
          -b mirror.gcr.io/library/node:20-bookworm-slim \\
          -f paas-artifacts/app-layer.tar \\
          -t "\${_push_ref}" &
        CRANE_APPEND_PID=\$!
        while kill -0 "\${CRANE_APPEND_PID}" 2>/dev/null; do
          echo "[image] (crane heartbeat) still packing or pushing… \$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          sleep "\${_hb}" || true
        done
        wait "\${CRANE_APPEND_PID}" && _crane_rc=0 || _crane_rc=\$?
      else
        "${craneBin}" ${craneInsecure} append \\
          -b mirror.gcr.io/library/node:20-bookworm-slim \\
          -f paas-artifacts/app-layer.tar \\
          -t "\${_push_ref}" && _crane_rc=0 || _crane_rc=\$?
      fi
      if [ "\${_crane_rc}" = "0" ]; then
        if [ "\${_push_ref_ip}" != "${imageRef}" ]; then
          echo "[image] pushed via IP ref — tagging nip.io alias ${imageRef}"
          "${craneBin}" ${craneInsecure} tag "\${_push_ref_ip}" "${imageRef}" || true
        fi
        break
      fi
      echo "[image] WARN: crane append failed (rc=\${_crane_rc}); try: bash paas/scripts/lab.sh harbor"
      if [ "\${_crane_attempt}" -ge "\${_crane_max}" ]; then
        exit "\${_crane_rc}"
      fi
      _crane_attempt=\$((_crane_attempt + 1))
      sleep 60
    done
    echo "[image] crane append finished; running crane mutate (same shell as append — monorepo-safe)"
    USE_STANDALONE=0
    if [ -f paas-artifacts/_crane_use_standalone ]; then
      USE_STANDALONE=\$(cat paas-artifacts/_crane_use_standalone)
    else
      echo "[image] WARN: paas-artifacts/_crane_use_standalone missing — assuming non-standalone layer"
    fi
    _mutate_max="\${JENKINS_CRANE_PUSH_RETRIES:-3}"
    _mutate_attempt=1
    _mutate_rc=1
    while [ "\${_mutate_attempt}" -le "\${_mutate_max}" ]; do
      echo "[image] crane mutate attempt \${_mutate_attempt}/\${_mutate_max} → ${imageRef}"
      if [ "\$USE_STANDALONE" = "1" ]; then
        "${craneBin}" ${craneInsecure} mutate "${imageRef}" \\
          -t "${imageRef}" \\
          --workdir=/app \\
          --entrypoint=/usr/local/bin/node \\
          --cmd=server.js \\
          --exposed-ports=3000/tcp && _mutate_rc=0 || _mutate_rc=\$?
      else
        "${craneBin}" ${craneInsecure} mutate "${imageRef}" \\
          -t "${imageRef}" \\
          --workdir=/app \\
          --entrypoint=/app/start-paas.sh \\
          --exposed-ports=3000/tcp && _mutate_rc=0 || _mutate_rc=\$?
      fi
      if [ "\${_mutate_rc}" = "0" ]; then
        break
      fi
      echo "[image] WARN: crane mutate failed (rc=\${_mutate_rc}); Harbor blob 502? wait and retry"
      if [ "\${_mutate_attempt}" -ge "\${_mutate_max}" ]; then
        exit "\${_mutate_rc}"
      fi
      _mutate_attempt=\$((_mutate_attempt + 1))
      sleep 45
    done
    echo "[image] crane mutate OK"
    ARTIFACT_REF="${artifactImageRef}"
    if [ -n "\${ARTIFACT_REF}" ] && [ "\${ARTIFACT_REF}" != "${imageRef}" ]; then
      echo "[image] crane copy → GitOps/cosign ref \${ARTIFACT_REF}"
      "${craneBin}" ${craneInsecure} copy "${imageRef}" "\${ARTIFACT_REF}" || echo "[image] WARN: crane copy to external Harbor ref failed (pull may still work via in-cluster push)"
    fi
    mkdir -p paas-artifacts
    REF="\${ARTIFACT_REF:-${artifactImageRef}}"
    DIGEST_REF="\$(${craneBin} ${craneInsecure} digest \${REF} 2>/dev/null | tr -d '\\r\\n' || true)"
    if [ -n "\${DIGEST_REF}" ]; then
      case "\${DIGEST_REF}" in
        sha256:*)
          REPO="\${REF%:*}"
          DIGEST_REF="\${REPO}@\${DIGEST_REF}"
          ;;
      esac
      echo "\${DIGEST_REF}" > paas-artifacts/image-digest-ref.txt
      echo "PAAS_IMAGE_DIGEST=\${DIGEST_REF}"
      echo "PAAS_IMAGE_DIGEST=\${DIGEST_REF}" >> paas-artifacts/cosign-meta.txt
    fi
  """

}

