// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626

def nonEmptyNoSpace(String value, String label) {
  if (!value?.trim()) {
    error("${label} is required")
  }
  if (value.trim().contains(" ")) {
    error("${label} must not contain spaces")
  }
}

def commandExists(String commandName) {
  return sh(script: "command -v ${commandName} >/dev/null 2>&1", returnStatus: true) == 0
}

def nonFatalStage(String label, Closure body) {
  catchError(buildResult: "SUCCESS", stageResult: "SUCCESS") {
    println "*** BEGIN : ${label} ***"
    body()
    println "*** END : ${label} ***"
  }
}

def securityMandatoryStage(String label, Closure body) {
  println "*** BEGIN : ${label} (mandatory) ***"
  body()
  println "*** END : ${label} (mandatory) ***"
}

def paasStepLog(String level, int step, String id, String msg) {
  def safe = (msg ?: "").replaceAll('[\\r\\n]+', ' ').take(500)
  println "PAAS_STEP_${level} step=${step} id=${id} msg=${safe}"
}
def paasStepOk(int step, String id, String msg) { paasStepLog('OK', step, id, msg) }
def paasStepWarn(int step, String id, String msg) { paasStepLog('WARN', step, id, msg) }
def paasStepFail(int step, String id, String msg) {
  paasStepLog('FAIL', step, id, msg)
  error("PAAS security step ${step} failed (${id}): ${msg}")
}
def paasStepSkip(int step, String reason) { println "PAAS_STEP_SKIP step=${step} reason=${reason.take(500)}" }

def uploadBomToDependencyTrack(String projId, String dtProjectName, String branchOrVersionLabel) {
  def inClusterDt = 'http://dtrack-dependency-track-api-server.dependency-track.svc.cluster.local:8080'
  def dtBase = params.DEPENDENCY_TRACK_BASE_URL?.trim() ?: env.DEPENDENCY_TRACK_BASE_URL ?: ''
  def jenkinsDtBase = params.JENKINS_DEPENDENCY_TRACK_BASE_URL?.trim() ?: env.JENKINS_DEPENDENCY_TRACK_BASE_URL ?: dtBase ?: inClusterDt
  def dtKey = params.DEPENDENCY_TRACK_API_KEY?.trim() ?: env.DEPENDENCY_TRACK_API_KEY ?: ""
  def ver = "${branchOrVersionLabel}-${env.BUILD_NUMBER}"
  def dtName = (dtProjectName ?: projId).trim()
  if (!dtKey) {
    paasStepFail(4, 'dependency-track', 'DEPENDENCY_TRACK_API_KEY is required')
  }
  if (!fileExists("sca/bom.json")) {
    paasStepFail(4, 'dependency-track', 'sca/bom.json missing — SBOM required before upload')
  }
  withEnv([
    "JENKINS_DT_BASE=${jenkinsDtBase}",
    "DT_BASE=${dtBase}",
    "DT_KEY=${dtKey}",
    "DT_VERSION=${ver}",
    "DT_PROJECT=${dtName}",
    "DT_PROJECT_TAG=${projId}",
    "PAAS_DT_UPLOAD_OPTIONAL=${(params.PAAS_DT_UPLOAD_OPTIONAL?.trim() ?: env.PAAS_DT_UPLOAD_OPTIONAL ?: 'false').trim()}"
  ]) {
    sh '''
      set +e
      echo "[paas-jenkinsfile] marker=dt-nodeport-first-20260619 (NodePort/env URLs before cluster DNS — built-in Jenkins agent)"
      echo "[paas-jenkinsfile] marker=dt-probe-only-upload-20260701 (no cluster DNS fallback on built-in agent)"
      dt_probe_ok() {
        u="$1"
        [ -z "$u" ] && return 1
        curl -fsS -m 10 "${u%/}/api/version" >/dev/null 2>&1
      }
      dt_upload_candidates() {
        for u in "${DT_BASE}" "${JENKINS_DT_BASE}"; do
          [ -z "$u" ] && continue
          printf '%s\n' "$u"
        done | awk '!seen[$0]++'
        if command -v getent >/dev/null 2>&1 && getent hosts dtrack-dependency-track-api-server.dependency-track.svc.cluster.local >/dev/null 2>&1; then
          for u in \
            "http://dtrack-dependency-track-api-server.dependency-track.svc.cluster.local:8080" \
            "http://dtrack-dependency-track-api-server.dependency-track:8080" \
            "http://dtrack-dependency-track-apiserver.dependency-track.svc.cluster.local:8080" \
            "http://dependency-track-apiserver.dependency-track.svc.cluster.local:8080" \
            "http://dtrack-apiserver.dependency-track.svc.cluster.local:8080"
          do
            printf '%s\n' "$u"
          done
        fi | awk '!seen[$0]++'
      }
      DT_PROBE_OK_BASES=""
      DT_BASE_PICKED=""
      while IFS= read -r _dt_probe; do
        [ -z "${_dt_probe}" ] && continue
        if dt_probe_ok "${_dt_probe}"; then
          DT_PROBE_OK_BASES="${DT_PROBE_OK_BASES}${_dt_probe}"$'\n'
          [ -z "${DT_BASE_PICKED}" ] && DT_BASE_PICKED="${_dt_probe}"
        fi
      done <<EOF
$(dt_upload_candidates)
EOF
      if [ -z "${DT_BASE_PICKED}" ]; then
        if [ -n "${DT_BASE}" ]; then
          DT_BASE_PICKED="${DT_BASE}"
        elif [ -n "${JENKINS_DT_BASE}" ]; then
          DT_BASE_PICKED="${JENKINS_DT_BASE}"
        fi
        if [ -n "${DT_BASE_PICKED}" ]; then
          DT_PROBE_OK_BASES="${DT_BASE_PICKED}"$'\n'
        fi
        echo "[sca] Dependency-Track /api/version probe failed on all bases — will still try upload via ${DT_BASE_PICKED:-<none>}"
      else
        echo "[sca] Dependency-Track base=${DT_BASE_PICKED}"
      fi
      DT_HTTP=""
      DT_BODY=""
      DT_UPLOAD_BASE=""
      dt_try_upload() {
        _dt_base="$1"
        [ -z "${_dt_base}" ] && return 1
        for _dt_try in 1 2 3; do
          DT_RESP="$(curl -sS -w '\\n__HTTP__%{http_code}' -X POST "${_dt_base%/}/api/v1/bom" \
            -H "X-Api-Key: ${DT_KEY}" \
            -F "autoCreate=true" \
            -F "projectName=${DT_PROJECT}" \
            -F "projectTags=${DT_PROJECT_TAG}" \
            -F "projectVersion=${DT_VERSION}" \
            -F "bom=@sca/bom.json" 2>&1)" || true
          DT_HTTP="$(printf '%s' "${DT_RESP}" | sed -n 's/^__HTTP__//p' | tail -1)"
          DT_BODY="$(printf '%s' "${DT_RESP}" | sed '/^__HTTP__/d')"
          if [ "${DT_HTTP}" = "200" ] || [ "${DT_HTTP}" = "201" ] || [ "${DT_HTTP}" = "202" ]; then
            DT_UPLOAD_BASE="${_dt_base}"
            return 0
          fi
          if [ "${DT_HTTP}" = "000" ] || [ "${DT_HTTP}" = "502" ] || [ "${DT_HTTP}" = "503" ] || [ "${DT_HTTP}" = "504" ]; then
            if [ "${_dt_try}" -lt 3 ]; then
              echo "[sca] Dependency-Track transient HTTP ${DT_HTTP} via ${_dt_base} (attempt ${_dt_try}/3) — retry in 10s"
              sleep 10
              continue
            fi
          fi
          return 1
        done
        return 1
      }
      DT_UPLOADED=0
      while IFS= read -r _dt_base; do
        [ -z "${_dt_base}" ] && continue
        if dt_try_upload "${_dt_base}"; then
          DT_UPLOADED=1
          break
        fi
      done <<EOF
$(printf '%s' "${DT_PROBE_OK_BASES}")
EOF
      if [ "${DT_UPLOADED}" = "1" ]; then
        echo "[sca] Dependency-Track upload OK (HTTP ${DT_HTTP}) base=${DT_UPLOAD_BASE:-${DT_BASE_PICKED}} project=${DT_PROJECT} version=${DT_VERSION}"
        echo "PAAS_STEP_OK step=4 id=dependency-track msg=SBOM uploaded to Dependency-Track HTTP ${DT_HTTP}"
      elif [ "${PAAS_DT_UPLOAD_OPTIONAL}" = "true" ] && [ -f sca/bom.json ]; then
        echo "[sca] WARN: Dependency-Track upload failed (HTTP ${DT_HTTP:-?}) — PAAS_DT_UPLOAD_OPTIONAL=true; continuing with local sca/bom.json"
        echo "PAAS_STEP_WARN step=4 id=dependency-track msg=SBOM kept locally; Dependency-Track unreachable (HTTP ${DT_HTTP:-?})"
      else
        echo "[sca] Dependency-Track upload failed (HTTP ${DT_HTTP:-?}) last base=${DT_BASE_PICKED} — rotate DEPENDENCY_TRACK_API_KEY if 401; ensure dtrack API server pod is Running"
        printf '%s\n' "${DT_BODY}" | head -c 800
        echo ""
        echo "PAAS_STEP_FAIL step=4 id=dependency-track msg=Dependency-Track upload HTTP ${DT_HTTP:-?}"
        exit 1
      fi
    '''
  }
}

def dtProjectNameForUpload(String projId, String imageRef) {
  def slug = (imageRef ?: "").tokenize('/').last()?.trim()
  if (slug?.contains(':')) {
    slug = slug.tokenize(':')[0]
  }
  return slug ?: projId
}

def materializeProjectBuildEnv(String appRoot) {
  def b64 = (params.PROJECT_BUILD_ENV_B64 ?: env.PROJECT_BUILD_ENV_B64 ?: '').trim()
  if (!b64) {
    println '[env] No PROJECT_BUILD_ENV_B64 — skip .env (Next.js/Firebase apps need NEXT_PUBLIC_* at build time; set Build env in PaaS Edit project, then Deploy again)'
    return false
  }
  def prefix = appRoot == '.' ? '' : "${appRoot}/"
  if (!fileExists("${prefix}package.json")) {
    println "[env] WARN: no package.json under ${appRoot} — skip .env materialize"
    return false
  }
  try {
    writeFile file: "${prefix}.paas-build-env.b64", text: b64
    ensureNodeTool()
            sh """
      set -eu
      cd '${appRoot}'
      if ! command -v node >/dev/null 2>&1; then
        echo '[env] ERROR: node required to decode PROJECT_BUILD_ENV_B64'
        exit 1
      fi
      node <<'NODE'
const fs = require('fs');
const b64 = fs.readFileSync('.paas-build-env.b64', 'utf8').trim();
let envMap;
try {
  envMap = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
} catch (e) {
  console.error('[env] ERROR: invalid PROJECT_BUILD_ENV_B64 JSON:', e.message);
  process.exit(1);
}
function dotenvLine(key, value) {
  const s = String(value);
  const escaped = s.replace(/\\\\/g, '\\\\\\\\').replace(/"/g, '\\\\"').replace(/\\n/g, '\\\\n').replace(/\\r/g, '');
  return key + '="' + escaped + '"';
}
const secretKey = (k) => /pass|secret|token|private|credential/i.test(k) && !/^NEXT_PUBLIC_/i.test(k);
let pkg = null;
try { pkg = JSON.parse(fs.readFileSync('package.json', 'utf8')); } catch (_) {}
const usesNext = Boolean(pkg && (pkg.dependencies?.next || pkg.devDependencies?.next));
if (usesNext && envMap.NODE_OPTIONS) {
  envMap.NODE_OPTIONS = String(envMap.NODE_OPTIONS)
    .split(/\\s+/)
    .filter((f) => f && f !== '--openssl-legacy-provider')
    .join(' ')
    .trim();
}
const lines = Object.entries(envMap || {})
  .filter(([k, v]) => k && v != null && String(v).trim() !== '')
  .map(([k, v]) => dotenvLine(k, v));
if (!lines.length) {
  console.error('[env] ERROR: PROJECT_BUILD_ENV_B64 decoded to empty map');
  process.exit(1);
}
const content = lines.join('\\n');
for (const name of ['.env', '.env.local', '.env.production', '.env.production.local']) {
  fs.writeFileSync(name, content);
}
const keySummary = Object.keys(envMap).sort().map((k) => (secretKey(k) ? k + '=<redacted>' : k)).join(', ');
console.log('[env] Wrote ' + lines.length + ' variable(s) to ' + process.cwd() + ' (' + keySummary + ')');
console.log('[env] NEXT_PUBLIC_* are baked during next build — K8s Helm env at deploy does not replace them');
NODE
      rm -f .paas-build-env.b64
    """
    ensureBuildEnvDockerignoreExcluded(appRoot)
    return true
  } catch (Exception e) {
    println "[env] WARN: could not materialize PROJECT_BUILD_ENV_B64: ${e.message}"
    return false
  }
}

def ensureBuildEnvDockerignoreExcluded(String appRoot) {
  def di = "${appRoot}/.dockerignore"
  if (!fileExists(di)) {
    return
  }
  def text = readFile file: di
  if (text.contains('!.env')) {
    return
  }
  if (!text.contains('.env')) {
    return
  }
  writeFile file: di, text: "${text.trim()}\n# PaaS: allow project build env for Next.js docker build\n!.env\n!.env.local\n!.env.production\n!.env.production.local\n"
  println "[env] Patched ${di} so .env files are included in docker build context"
}

def paasSourceBuildEnvShellSnippet() {
  return '''
if [ -f .env ]; then
  # Do not use ". ./.env" — unquoted values with spaces (e.g. app passwords) break sh and leak under set -x.
  set +x 2>/dev/null || true
  _paas_env_file="$(mktemp "${TMPDIR:-/tmp}/paas-env.XXXXXX")"
  node <<'NODE' > "${_paas_env_file}"
const fs = require('fs');
const secretKey = (k) => /pass|secret|token|private|credential/i.test(k) && !/^NEXT_PUBLIC_/i.test(k);
function parseLine(line) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) return null;
  const eq = trimmed.indexOf('=');
  if (eq <= 0) return null;
  const key = trimmed.slice(0, eq).trim();
  let val = trimmed.slice(eq + 1).trim();
  if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
    val = val.slice(1, -1).replace(/\\\\"/g, '"').replace(/\\\\\\\\/g, '\\\\');
  }
  return { key, val };
}
const exports = [];
const keys = [];
for (const line of fs.readFileSync('.env', 'utf8').split(/\\n/)) {
  const row = parseLine(line);
  if (!row) continue;
  exports.push('export ' + row.key + '=' + JSON.stringify(row.val));
  keys.push(row.key);
}
if (!exports.length) {
  console.error('[env] ERROR: .env has no KEY=value lines');
  process.exit(1);
}
process.stdout.write(exports.join('\\n'));
const summary = keys.map((k) => (secretKey(k) ? k + '=<redacted>' : k)).join(', ');
console.error('[env] loaded ' + keys.length + ' variable(s) for build (' + summary + ')');
NODE
  set -a
  # shellcheck disable=SC1090
  . "${_paas_env_file}"
  set +a
  rm -f "${_paas_env_file}"
fi
'''
}

def projectBuildEnvPresent() {
  return (params.PROJECT_BUILD_ENV_B64 ?: env.PROJECT_BUILD_ENV_B64 ?: '').trim().length() > 0
}

def paasForceFreshNextBuildShellSnippet() {
  return '''
if [ -n "${PROJECT_BUILD_ENV_B64:-}" ]; then
  echo "[env] PROJECT_BUILD_ENV_B64 set — removing .next so Firebase/NEXT_PUBLIC_* are recompiled"
  rm -rf .next
fi
'''
}

def patchNextBuildEnvIntoConfig(String appRoot = '.') {
  def b64 = (params.PROJECT_BUILD_ENV_B64 ?: env.PROJECT_BUILD_ENV_B64 ?: '').trim()
  if (!b64) {
    return false
  }
  def prefix = appRoot == '.' ? '' : "${appRoot}/"
  if (!fileExists("${prefix}package.json")) {
    return false
  }
  def hasNextConfig = fileExists("${prefix}next.config.mjs") || fileExists("${prefix}next.config.js") || fileExists("${prefix}next.config.ts")
  if (!hasNextConfig) {
    return false
  }
  ensureNodeTool()
  withEnv(["PAAS_BUILD_ENV_B64=${b64}"]) {
    sh """
      set +e
      cd '${appRoot}'
      if ! command -v node >/dev/null 2>&1; then
        echo "[env] WARN: node unavailable — skip next.config env patch"
        exit 0
      fi
      node <<'NODE'
const fs = require('fs');
const b64 = process.env.PAAS_BUILD_ENV_B64 || '';
if (!b64) process.exit(0);
let envMap;
try {
  envMap = JSON.parse(Buffer.from(b64, 'base64').toString('utf8'));
} catch (e) {
  console.log('[env] WARN: could not decode PAAS_BUILD_ENV_B64 for next.config patch:', e.message);
  process.exit(0);
}
const entries = Object.entries(envMap || {}).filter(([k, v]) => k && v != null && String(v).trim() !== '');
if (!entries.length) process.exit(0);
const envLines = entries.map(([k, v]) => '    ' + k + ': ' + JSON.stringify(String(v)) + ',').join('\\n');
const envBlock = '  // __PAAS_BUILD_ENV__\\n  env: {\\n' + envLines + '\\n  },';
for (const f of ['next.config.mjs', 'next.config.js', 'next.config.ts']) {
  if (!fs.existsSync(f)) continue;
  let txt = fs.readFileSync(f, 'utf8');
  txt = txt.replace(/\\n  \\/\\/ __PAAS_BUILD_ENV__[\\s\\S]*?\\n  \\},\\n/g, '\\n');
  let patched = null;
  if (/const\\s+nextConfig[^=]*=\\s*\\{/.test(txt)) {
    patched = txt.replace(/const\\s+nextConfig[^=]*=\\s*\\{/, (m) => m + '\\n' + envBlock);
  } else if (/export\\s+default\\s*\\{/.test(txt)) {
    patched = txt.replace(/export\\s+default\\s*\\{/, (m) => m + '\\n' + envBlock);
  }
  if (!patched || patched === txt) {
    console.log('[env] ERROR: could not patch ' + f + ' — unrecognized shape');
    process.exit(1);
  }
  fs.writeFileSync(f, patched);
  console.log('[env] patched ' + f + ' with env: { ' + entries.map(([k]) => k).join(', ') + ' }');
  process.exit(0);
}
console.log('[env] ERROR: no next.config.* found to patch');
process.exit(1);
NODE
    """
  }
  return true
}

def writeNginxPaasDefaultConf(String appRoot = '.') {
  def confDir = appRoot == '.' ? 'paas-artifacts/_nginx_conf/conf.d' : "${appRoot}/paas-artifacts/_nginx_conf/conf.d"
  writeFile file: "${confDir}/default.conf", text: '''server {
    listen 80;
    server_name _;
    root /usr/share/nginx/html;
    index index.html;
    location / {
        try_files $uri $uri/ /index.html;
    }
}
'''
}

def verifyNextPublicEnvInBuild(String appRoot = '.') {
  if (!projectBuildEnvPresent()) {
    return
  }
  def prefix = appRoot == '.' ? '' : "${appRoot}/"
  if (!fileExists("${prefix}package.json")) {
    return
  }
  sh """
    set +e
    cd '${appRoot}'
    if ! node -e "const p=require('./package.json');const d={...p.dependencies||{},...p.devDependencies||{}};process.exit(d.next?0:1)" 2>/dev/null; then
      echo "[env] verify: not Next.js — skip NEXT_PUBLIC bundle check (Express/API-only OK)"
      exit 0
    fi
    IS_FIREBASE=0
    if node -e "const p=require('./package.json');const d={...p.dependencies||{},...p.devDependencies||{}};process.exit(d.firebase||d['@firebase/app']?0:1)" 2>/dev/null; then
      IS_FIREBASE=1
    fi
    HAS_NEXT_PUBLIC=0
    if grep -qE '^NEXT_PUBLIC_' .env .env.production 2>/dev/null; then
      HAS_NEXT_PUBLIC=1
    fi
    if [ "\$IS_FIREBASE" != "1" ] && [ "\$HAS_NEXT_PUBLIC" != "1" ]; then
      echo "[env] verify: no NEXT_PUBLIC_* in project env — skip bundle check"
      exit 0
    fi
    if [ ! -d .next ]; then
      echo "[env] ERROR: .next missing after build — cannot verify NEXT_PUBLIC_* in bundle"
      exit 1
    fi
    _paas_grep_next_out() {
      grep -Rql "\$1" .next/static .next/server .next/standalone 2>/dev/null
    }
    NEEDLE=""
    if [ -f .env.production ]; then
      NEEDLE=\$(grep -E '^NEXT_PUBLIC_FIREBASE_API_KEY=' .env.production 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\\"' | tr -d "\\'" | cut -c1-12)
    fi
    if [ -z "\$NEEDLE" ] && [ -f .env ]; then
      NEEDLE=\$(grep -E '^NEXT_PUBLIC_FIREBASE_API_KEY=' .env 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\\"' | tr -d "\\'" | cut -c1-12)
    fi
    if [ -n "\$NEEDLE" ]; then
      if _paas_grep_next_out "\$NEEDLE"; then
        echo "[env] verify OK: Firebase API key prefix found in .next output"
        exit 0
      fi
      echo "[env] ERROR: next build finished but NEXT_PUBLIC_FIREBASE_API_KEY is not in .next — env was not baked"
      exit 1
    fi
    if grep -Rq 'NEXT_PUBLIC_FIREBASE' .next/static .next/server 2>/dev/null; then
      echo "[env] verify OK: NEXT_PUBLIC_FIREBASE references found in build output"
      exit 0
    fi
    if grep -qE 'NEXT_PUBLIC_|env:\\s*\\{' next.config.ts next.config.js next.config.mjs 2>/dev/null; then
      echo "[env] verify OK: next.config env patch present (NEXT_PUBLIC_* may be unused in client bundle — OK for simple Next apps)"
      exit 0
    fi
    if [ "\$IS_FIREBASE" = "1" ]; then
      echo "[env] ERROR: Firebase app but NEXT_PUBLIC_* not found in .next — check PROJECT_BUILD_ENV_B64 and next build logs"
      exit 1
    fi
    echo "[env] WARN: NEXT_PUBLIC_* set in Application environment but not referenced in client bundle — continuing (non-Firebase app)"
    exit 0
  """
}

def dockerfileHasProductionBuild(String dockerfilePath) {
  if (!fileExists(dockerfilePath)) {
    return false
  }
  def text = readFile file: dockerfilePath
  return (text =~ /(?i)(next build|npm run build|npm run build:ci|yarn build|pnpm run build|pnpm build|ng build|vite build)/)
}

def resolveNodeVersion(String appRoot = '.') {
  def override = (env.JENKINS_PAAS_NODE_VERSION ?: '').trim()
  if (override) {
    return override
  }
  def root = (appRoot ?: '.').trim() ?: '.'
  def pkgPath = root == '.' ? 'package.json' : "${root}/package.json"
  if (fileExists(pkgPath)) {
    try {
      def pkg = readFile(pkgPath)
      if (pkg.contains('"@angular/core"')) {
        def m = (pkg =~ /"@angular\/core"\s*:\s*"\^?(\d+)/)
        if (m.find()) {
          def major = (m.group(1) as Integer)
          if (major >= 17) { return '20.19.5' }
          if (major >= 13) { return '18.20.4' }
          return '16.20.2'
        }
        return '16.20.2'
      }
    } catch (Exception ignored) {}
  }
  return '20.19.5'
}

def isLegacyAngularProject(String appRoot = '.') {
  def root = (appRoot ?: '.').trim() ?: '.'
  def pkgPath = root == '.' ? 'package.json' : "${root}/package.json"
  if (!fileExists(pkgPath)) {
    return false
  }
  try {
    def pkg = readFile(pkgPath)
    if (!pkg.contains('"@angular/core"')) {
      return false
    }
    def m = (pkg =~ /"@angular\/core"\s*:\s*"\^?(\d+)/)
    if (m.find()) {
      return (m.group(1) as Integer) < 13
    }
    return true
  } catch (Exception ignored) {
    return true
  }
}

def shouldDeferAngularBuildToStep6(String appRoot, String dockerfilePath = 'Dockerfile') {
  def root = (appRoot ?: '.').trim() ?: '.'
  def pkgPath = root == '.' ? 'package.json' : "${root}/package.json"
  if (!fileExists(pkgPath)) {
    return false
  }
  try {
    if (readFile(pkgPath).contains('"@angular/core"')) {
      return true
    }
  } catch (Exception ignored) {
    return false
  }
  def fw = detectProjectFramework(root)
  if (fw in ['vite-react', 'spa'] && resolveCraneRuntimeStack(root, dockerfilePath) == 'nginx') {
    return true
  }
  return false
}

def resolveCraneRuntimeStack(String appRoot, String dockerfilePath) {
  def root = (appRoot ?: '.').trim() ?: '.'
  if (fileExists("${root}/requirements.txt") || fileExists("${root}/pyproject.toml")
      || fileExists('requirements.txt') || fileExists('pyproject.toml')) {
    return 'python'
  }
  def fw = detectProjectFramework(root)
  if (fw == 'python') {
    return 'python'
  }
  def df = (dockerfilePath ?: 'Dockerfile').trim()
  if (fileExists(df)) {
    def text = readFile(df)
    if (text =~ /(?i)FROM\s+[^\n]*python/ || text =~ /(?i)(gunicorn|uvicorn|pip install)/) {
      return 'python'
    }
    if (text =~ /(?i)FROM\s+[^\n]*nginx/) {
      return 'nginx'
    }
  }
  if (fw == 'angular') {
    return 'nginx'
  }
  if (fw in ['vite-react', 'spa']) {
    return 'nginx'
  }
  return 'node'
}

def paasOpensslLegacyShellSnippet() {
  return '''
    _paas_is_nextjs() {
      case "${PAAS_FRAMEWORK:-}" in next) return 0 ;; esac
      [ -f package.json ] && grep -qE '"next"[[:space:]]*:' package.json 2>/dev/null
    }
    _paas_sanitize_node_options() {
      # Next.js 13+ / Turbopack workers reject --openssl-legacy-provider in NODE_OPTIONS (ERR_WORKER_INVALID_EXEC_ARGV).
      if _paas_is_nextjs; then
        export NODE_OPTIONS="$(printf '%s' "${NODE_OPTIONS:-}" | tr ' ' '\\n' | grep -v '^--openssl-legacy-provider$' | tr '\\n' ' ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      fi
    }
    _paas_openssl_legacy() {
      if _paas_is_nextjs; then
        return 0
      fi
      case "${PAAS_FRAMEWORK:-}" in
        angular|spa|node|vite-react)
          case "$(node -v 2>/dev/null || echo v0)" in
            v17*|v18*|v19*|v20*|v21*|v22*)
              case "${NODE_OPTIONS:-}" in
              esac
              ;;
          esac
          ;;
      esac
    }
    _paas_sanitize_node_options
    _paas_openssl_legacy
'''
}

def detectProjectFrameworkFromPackageText(String pkg) {
  if (!pkg?.trim()) {
    return 'node'
  }
  if (pkg =~ /"next"\s*:\s*["\^~]/) {
    return 'next'
  }
  if (pkg.contains('"@angular/core"')) {
    return 'angular'
  }
  if (pkg.contains('"@nestjs/core"')) {
    return 'nestjs'
  }
  if (pkg =~ /"express"\s*:\s*["\^~]/) {
    return 'express'
  }
  if (pkg.contains('"vite"') || pkg.contains('"@vitejs/plugin-react"') || pkg.contains('"react-scripts"')) {
    return 'vite-react'
  }
  if (pkg.contains('"react"') || pkg.contains('"vue"')) {
    return 'spa'
  }
  if (pkg =~ /"build"\s*:/ || pkg =~ /"build:ci"\s*:/ || pkg =~ /"start"\s*:/) {
    return 'node'
  }
  return 'node'
}

def detectProjectFramework(String appRoot = '.') {
  def root = (appRoot ?: '.').trim() ?: '.'
  def pkgPath = root == '.' ? 'package.json' : "${root}/package.json"
  if (fileExists(pkgPath)) {
    try {
      return detectProjectFrameworkFromPackageText(readFile(pkgPath))
    } catch (Exception ignored) {
      return 'node'
    }
  }
  if (fileExists("${root}/requirements.txt") || fileExists("${root}/pyproject.toml")
      || fileExists('requirements.txt') || fileExists('pyproject.toml')) {
    return 'python'
  }
  if (fileExists("${root}/pom.xml") || fileExists('pom.xml')) {
    return 'java'
  }
  return 'unknown'
}

def prependPath(String path) {
  env.PATH = "${path}:${env.PATH}"
}

def resolvePortableNodeBin(String nodeVer = '20.19.5') {
  def cacheRoot = (env.JENKINS_PAAS_NODE_CACHE ?: "").trim()
  if (!cacheRoot) {
    def base = (env.JENKINS_HOME ?: env.HOME ?: "").trim()
    cacheRoot = base ? "${base}/.jenkins-paas-cache/node" : "${pwd()}/.paas-tools"
  }
  def candidate = "${cacheRoot}/node-v${nodeVer}-linux-x64/bin/node"
  if (fileExists(candidate)) {
    return candidate
  }
  if (commandExists('node')) {
    return 'node'
  }
  return candidate
}

def ensureNodeTool(String nodeVer = null) {
  def targetVer = (nodeVer ?: resolveNodeVersion()).trim()
  if (!targetVer) {
    targetVer = '20.19.5'
  }
  def cacheRoot = (env.JENKINS_PAAS_NODE_CACHE ?: "").trim()
  if (!cacheRoot) {
    def base = (env.JENKINS_HOME ?: env.HOME ?: "").trim()
    cacheRoot = base ? "${base}/.jenkins-paas-cache/node" : "${pwd()}/.paas-tools"
  }
  def nodeDir = "${cacheRoot}/node-v${targetVer}-linux-x64"
  if (commandExists("npm")) {
    def current = ''
    try {
      current = sh(script: 'node -v 2>/dev/null | sed "s/^v//"', returnStdout: true).trim()
    } catch (Exception ignored) {}
    if (current == targetVer) {
      return
    }
    if (fileExists("${nodeDir}/bin/npm")) {
      println "[tooling] Node on PATH is v${current ?: 'unknown'}; using portable v${targetVer} → ${nodeDir}"
      prependPath("${nodeDir}/bin")
      return
    }
  }
  nodeVer = targetVer
  println "[tooling] portable Node.js ${nodeVer} → ${nodeDir} (set JENKINS_PAAS_NODE_VERSION to override; JENKINS_PAAS_NODE_CACHE for cache root)"
  withEnv(["ENS_NODE_BOOT_VER=${nodeVer}", "ENS_NODE_BOOT_DIR=${nodeDir}"]) {
    sh '''#!/bin/sh
set -eu
NODE_VERSION="${ENS_NODE_BOOT_VER}"
NODE_DIR="${ENS_NODE_BOOT_DIR}"
CACHE_PARENT="$(dirname "${NODE_DIR}")"
LOCK_DIR="${CACHE_PARENT}/.node-install.lock"
mkdir -p "${CACHE_PARENT}"

if [ -x "${NODE_DIR}/bin/npm" ]; then
  exit 0
fi

_wait=0
while [ ! -x "${NODE_DIR}/bin/npm" ]; do
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    break
  fi
  _wait=$((_wait + 1))
  if [ "${_wait}" -gt 360 ]; then
    echo "[tooling] ERROR: timeout waiting for shared Node.js install lock" >&2
    exit 1
  fi
  echo "[tooling] another build is installing Node.js — waiting (${_wait})…"
  sleep 5
done

if [ -x "${NODE_DIR}/bin/npm" ]; then
  rmdir "${LOCK_DIR}" 2>/dev/null || true
  exit 0
fi

TDIR="$(mktemp -d)"
cleanup() {
  kill "${HB_PID:-}" 2>/dev/null || true
  rm -rf "${TDIR}" 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[tooling] downloading Node.js ${NODE_VERSION} tarball…"
(
  _n=0
  while true; do
    sleep 20
    _n=$((_n + 1))
    echo "[tooling] Node.js download still running (${_n}×20s) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done
) &
HB_PID=$!

curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 1800 \
  "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.gz" \
  -o "${TDIR}/node.tar.gz"
kill "${HB_PID}" 2>/dev/null || true
HB_PID=""
tar -xzf "${TDIR}/node.tar.gz" -C "${TDIR}"

STALE="${NODE_DIR}.stale.$$"
rm -rf "${STALE}" 2>/dev/null || true
if [ -e "${NODE_DIR}" ]; then
  mv "${NODE_DIR}" "${STALE}" 2>/dev/null || true
  rm -rf "${STALE}" 2>/dev/null || find "${STALE}" -mindepth 1 -delete 2>/dev/null || true
  if [ -e "${NODE_DIR}" ]; then
    find "${NODE_DIR}" -mindepth 1 -delete 2>/dev/null || rm -rf "${NODE_DIR}" 2>/dev/null || true
  fi
fi
mv "${TDIR}/node-v${NODE_VERSION}-linux-x64" "${NODE_DIR}"
rmdir "${LOCK_DIR}" 2>/dev/null || true
LOCK_DIR=""
'''
  }
  prependPath("${nodeDir}/bin")
}

def ensurePythonTool(String pyVer = null) {
  def targetVer = (pyVer ?: (env.JENKINS_PAAS_PYTHON_VERSION ?: '3.12.7')).trim()
  if (commandExists("python3")) {
    return
  }
  def cacheRoot = (env.JENKINS_PAAS_PYTHON_CACHE ?: "").trim()
  if (!cacheRoot) {
    def base = (env.JENKINS_HOME ?: env.HOME ?: "").trim()
    cacheRoot = base ? "${base}/.jenkins-paas-cache/python" : "${pwd()}/.paas-tools/python"
  }
  def buildTag = (env.JENKINS_PAAS_PYTHON_BUILD_TAG ?: '20241016').trim()
  def pyDir = "${cacheRoot}/cpython-${targetVer}-install_only"
  if (fileExists("${pyDir}/bin/python3")) {
    println "[tooling] portable Python ${targetVer} → ${pyDir}"
    prependPath("${pyDir}/bin")
    return
  }
  println "[tooling] portable Python ${targetVer} → ${pyDir} (set JENKINS_PAAS_PYTHON_VERSION / JENKINS_PAAS_PYTHON_CACHE to override)"
  withEnv(["ENS_PY_BOOT_VER=${targetVer}", "ENS_PY_BOOT_TAG=${buildTag}", "ENS_PY_BOOT_DIR=${pyDir}"]) {
    sh '''#!/bin/sh
set -eu
PY_VERSION="${ENS_PY_BOOT_VER}"
PY_TAG="${ENS_PY_BOOT_TAG}"
PY_DIR="${ENS_PY_BOOT_DIR}"
CACHE_PARENT="$(dirname "${PY_DIR}")"
LOCK_DIR="${CACHE_PARENT}/.python-install.lock"
mkdir -p "${CACHE_PARENT}"
if [ -x "${PY_DIR}/bin/python3" ]; then
  exit 0
fi
_wait=0
while [ ! -x "${PY_DIR}/bin/python3" ]; do
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    break
  fi
  _wait=$((_wait + 1))
  if [ "${_wait}" -gt 360 ]; then
    echo "[tooling] ERROR: timeout waiting for shared Python install lock" >&2
    exit 1
  fi
  echo "[tooling] another build is installing Python — waiting (${_wait})…"
  sleep 5
done
if [ -x "${PY_DIR}/bin/python3" ]; then
  rmdir "${LOCK_DIR}" 2>/dev/null || true
  exit 0
fi
TDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TDIR}" 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT
TARBALL="cpython-${PY_VERSION}+${PY_TAG}-x86_64-unknown-linux-gnu-install_only.tar.gz"
URL="https://github.com/indygreg/python-build-standalone/releases/download/${PY_TAG}/${TARBALL}"
echo "[tooling] downloading Python ${PY_VERSION} (${PY_TAG})…"
curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 1800 "${URL}" -o "${TDIR}/python.tar.gz"
tar -xzf "${TDIR}/python.tar.gz" -C "${TDIR}"
rm -rf "${PY_DIR}" 2>/dev/null || true
mv "${TDIR}/python" "${PY_DIR}"
rmdir "${LOCK_DIR}" 2>/dev/null || true
LOCK_DIR=""
'''
  }
  prependPath("${pyDir}/bin")
}

def patchNextStandaloneConfigIfNeeded(String appRoot = '.') {
  def prefix = appRoot == '.' ? '' : "${appRoot}/"
  if (!fileExists("${prefix}package.json")) {
    return
  }
  def hasNextConfig = fileExists("${prefix}next.config.mjs") || fileExists("${prefix}next.config.js") || fileExists("${prefix}next.config.ts")
  if (!hasNextConfig) {
    return
  }
  ensureNodeTool()
  sh """
    set +e
    cd '${appRoot}'
    if ! command -v node >/dev/null 2>&1; then
      echo "[build] WARN: node unavailable — skip next.config standalone patch (ensureNodeTool should have installed portable Node.js)"
      exit 0
    fi
    node <<'NODE'
const fs = require('fs');
for (const f of ['next.config.mjs', 'next.config.js', 'next.config.ts']) {
  if (!fs.existsSync(f)) continue;
  const txt = fs.readFileSync(f, 'utf8');
  if (/output\\s*:\\s*['"]standalone['"]/i.test(txt)) {
    console.log('[build] ' + f + ' already has output standalone');
    process.exit(0);
  }
  let patched = txt;
  if (/const\\s+nextConfig(?:\\s*:\\s*\\w+)?\\s*=\\s*\\{/.test(txt)) {
    patched = txt.replace(/const\\s+nextConfig(?:\\s*:\\s*\\w+)?\\s*=\\s*\\{/, "const nextConfig = {\\n  output: 'standalone',");
  } else if (/export\\s+default\\s*\\{/.test(txt)) {
    patched = txt.replace(/export\\s+default\\s*\\{/, "export default {\\n  output: 'standalone',");
  } else {
    console.log('[build] skip standalone patch — unrecognized ' + f + ' shape');
    process.exit(0);
  }
  fs.writeFileSync(f, patched);
  console.log('[build] patched ' + f + " with output: 'standalone'");
  process.exit(0);
}
NODE
  """
}

def ensureCraneTool() {
  if (commandExists("crane")) {
    return "crane"
  }
  def craneVer = "0.20.6"
  def cacheRoot = (env.JENKINS_PAAS_CRANE_CACHE ?: "").trim()
  if (!cacheRoot) {
    def base = (env.JENKINS_HOME ?: env.HOME ?: "").trim()
    cacheRoot = base ? "${base}/.jenkins-paas-cache/crane" : "${pwd()}/.paas-tools/crane"
  }
  def craneBin = "${cacheRoot}/crane-v${craneVer}/crane"
  println "[tooling] crane missing on PATH; using ${craneBin} (cached under JENKINS_HOME — not re-downloaded each checkout)"
  withEnv(["ENS_CRANE_VER=${craneVer}", "ENS_CRANE_BIN=${craneBin}"]) {
    sh '''#!/bin/sh
set -eu
CRANE_VERSION="${ENS_CRANE_VER}"
CRANE_BIN="${ENS_CRANE_BIN}"
CACHE_PARENT="$(dirname "${CRANE_BIN}")"
LOCK_DIR="${CACHE_PARENT}/.crane-install.lock"
mkdir -p "${CACHE_PARENT}"

if [ -x "${CRANE_BIN}" ]; then
  exit 0
fi

_wait=0
while [ ! -x "${CRANE_BIN}" ]; do
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    break
  fi
  _wait=$((_wait + 1))
  if [ "${_wait}" -gt 120 ]; then
    echo "[tooling] ERROR: timeout waiting for shared crane install lock" >&2
    exit 1
  fi
  echo "[tooling] another build is installing crane — waiting (${_wait})…"
  sleep 5
done

if [ -f "${CRANE_BIN}" ] && [ ! -x "${CRANE_BIN}" ]; then
  chmod +x "${CRANE_BIN}" 2>/dev/null || true
fi

if [ -x "${CRANE_BIN}" ]; then
  rmdir "${LOCK_DIR}" 2>/dev/null || true
  exit 0
fi

TDIR="$(mktemp -d)"
cleanup() {
  kill "${HB_PID:-}" 2>/dev/null || true
  rm -rf "${TDIR}" 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[tooling] downloading crane v${CRANE_VERSION} (once per Jenkins home)…"
(
  _n=0
  while true; do
    sleep 15
    _n=$((_n + 1))
    echo "[tooling] crane download still running (${_n}×15s) $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  done
) &
HB_PID=$!

curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 600 \
  "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_x86_64.tar.gz" \
  -o "${TDIR}/crane.tar.gz"
kill "${HB_PID}" 2>/dev/null || true
HB_PID=""
mkdir -p "$(dirname "${CRANE_BIN}")"
tar -xzf "${TDIR}/crane.tar.gz" -C "${TDIR}" crane
mv "${TDIR}/crane" "${CRANE_BIN}"
chmod +x "${CRANE_BIN}"
rmdir "${LOCK_DIR}" 2>/dev/null || true
LOCK_DIR=""
'''
  }
  return craneBin
}

def ensureHelmTool() {
  if (commandExists("helm")) {
    return "helm"
  }
  def helmVer = "3.16.3"
  def cacheRoot = (env.JENKINS_PAAS_HELM_CACHE ?: "").trim()
  if (!cacheRoot) {
    def base = (env.JENKINS_HOME ?: env.HOME ?: "").trim()
    cacheRoot = base ? "${base}/.jenkins-paas-cache/helm" : "${pwd()}/.paas-tools/helm"
  }
  def helmBin = "${cacheRoot}/helm-v${helmVer}/helm"
  println "[tooling] helm missing on PATH; using ${helmBin} (cached under JENKINS_HOME — set JENKINS_PAAS_HELM_CACHE to override)"
  withEnv(["ENS_HELM_VER=${helmVer}", "ENS_HELM_BIN=${helmBin}"]) {
    sh '''#!/bin/sh
set -eu
HELM_VERSION="${ENS_HELM_VER}"
HELM_BIN="${ENS_HELM_BIN}"
CACHE_PARENT="$(dirname "${HELM_BIN}")"
LOCK_DIR="${CACHE_PARENT}/.helm-install.lock"
mkdir -p "${CACHE_PARENT}"

if [ -x "${HELM_BIN}" ]; then
  exit 0
fi

_wait=0
while [ ! -x "${HELM_BIN}" ]; do
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    break
  fi
  _wait=$((_wait + 1))
  if [ "${_wait}" -gt 120 ]; then
    echo "[tooling] ERROR: timeout waiting for shared helm install lock" >&2
    exit 1
  fi
  echo "[tooling] another build is installing helm — waiting (${_wait})…"
  sleep 5
done

if [ -x "${HELM_BIN}" ]; then
  rmdir "${LOCK_DIR}" 2>/dev/null || true
  exit 0
fi

TDIR="$(mktemp -d)"
cleanup() {
  rm -rf "${TDIR}" 2>/dev/null || true
  rmdir "${LOCK_DIR}" 2>/dev/null || true
}
trap cleanup EXIT

echo "[tooling] downloading helm v${HELM_VERSION} (once per Jenkins home)…"
curl -fsSL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 600 \
  "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" \
  -o "${TDIR}/helm.tar.gz"
mkdir -p "$(dirname "${HELM_BIN}")"
tar -xzf "${TDIR}/helm.tar.gz" -C "${TDIR}" linux-amd64/helm
mv "${TDIR}/linux-amd64/helm" "${HELM_BIN}"
chmod +x "${HELM_BIN}"
rmdir "${LOCK_DIR}" 2>/dev/null || true
LOCK_DIR=""
'''
  }
  return helmBin
}

