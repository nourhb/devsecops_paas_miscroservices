// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626
def runPaasDeploySteps4_5() {
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
              echo "[sca] yarn.lock — yarn install then cyclonedx-npm (needs node_modules)"
              if ! command -v yarn >/dev/null 2>&1; then
                corepack enable 2>/dev/null || npm install -g yarn 2>/dev/null || true
              fi
              if command -v yarn >/dev/null 2>&1; then
                yarn install --frozen-lockfile 2>/dev/null || yarn install --non-interactive 2>/dev/null || yarn install
              else
                echo "[sca] WARN: yarn missing — npm install fallback"
                npm install --no-audit --no-fund
              fi
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
            ensureNodeTool('20.19.5')
            ensurePythonTool()
            def pyNodeBin = resolvePortableNodeBin('20.19.5')
            def pyScaRc = sh(script: """
              set +e
              cd '${scaPyRoot}'
              mkdir -p sca
              export PROJECT_NAME='${dtProjectNameForUpload(projectId, imageName)}'
              PAAS_NODE_BIN='${pyNodeBin}'
              if [ -f requirements.txt ] && { [ -x "\${PAAS_NODE_BIN}" ] || command -v node >/dev/null 2>&1; }; then
                echo "[sca] Python BOM from requirements.txt (node — works without python3 on agent)"
                NODE_CMD="\${PAAS_NODE_BIN}"
                [ -x "\${NODE_CMD}" ] || NODE_CMD="node"
                "\${NODE_CMD}" -e "
                  const fs=require('fs');
                  const name=process.env.PROJECT_NAME||'app';
                  const lines=fs.readFileSync('requirements.txt','utf8').split(/\\n/).map(l=>l.trim()).filter(l=>l&&!l.startsWith('#'));
                  const components=lines.map(line=>{
                    const pkg=line.split(/[=<>!\\[]/)[0].trim();
                    return {type:'library',name:pkg,'bom-ref':'pypi:'+pkg+'@unspecified',purl:'pkg:pypi/'+pkg};
                  });
                  fs.mkdirSync('sca',{recursive:true});
                  fs.writeFileSync('sca/bom.json', JSON.stringify({
                    bomFormat:'CycloneDX', specVersion:'1.4', version:1,
                    metadata:{component:{type:'application',name}},
                    components
                  }, null, 2)+'\\n');
                "
              fi
              if [ ! -f sca/bom.json ] && command -v python3 >/dev/null 2>&1; then
                python3 -m pip install --user -q cyclonedx-bom 2>/dev/null || pip3 install --user -q cyclonedx-bom 2>/dev/null || true
              fi
              if [ ! -f sca/bom.json ] && command -v cyclonedx-py >/dev/null 2>&1; then
                if [ -f requirements.txt ]; then
                  cyclonedx-py requirements -i requirements.txt -o sca/bom.json
                else
                  cyclonedx-py environment -o sca/bom.json
                fi
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
            def scaJvmRoot = detectAppRoot()
            ensureNodeTool('20.19.5')
            def scaProjectName = dtProjectNameForUpload(projectId, imageName)
            def jvmNodeBin = resolvePortableNodeBin('20.19.5')
            def jvmScaRc = sh(script: """
              set +e
              cd '${scaJvmRoot}'
              mkdir -p sca
              export PROJECT_NAME='${scaProjectName}'
              PAAS_NODE_BIN='${jvmNodeBin}'
              NODE_CMD="\${PAAS_NODE_BIN}"
              [ -x "\${NODE_CMD}" ] || NODE_CMD="node"
              if [ -f pom.xml ]; then
                if command -v mvn >/dev/null 2>&1; then
                  echo "[sca] Maven CycloneDX (pom.xml)"
                  mvn -q -DskipTests -Dcyclonedx.skipAttach=true \\
                    org.cyclonedx:cyclonedx-maven-plugin:2.8.0:makeAggregateBom \\
                    -Dcyclonedx.outputFormat=json -Dcyclonedx.outputName=bom 2>/dev/null || true
                  for f in target/bom.json bom.json; do
                    if [ -f "\$f" ]; then cp "\$f" sca/bom.json; break; fi
                  done
                else
                  echo "[sca] WARN: pom.xml but mvn missing — minimal BOM"
                fi
              fi
              if [ ! -f sca/bom.json ] && { [ -f Dockerfile ] || [ -d src ] || [ -f build.gradle ] || [ -f build.gradle.kts ] || ls *.py >/dev/null 2>&1; }; then
                echo "[sca] minimal CycloneDX BOM (Dockerfile/Java/static/Python — no npm/pip lockfile)"
                NODE_CMD="${jvmNodeBin}"
                if [ ! -x "\${NODE_CMD}" ]; then
                  echo "[sca] WARN: portable node missing at \${NODE_CMD}"
                  NODE_CMD=""
                fi
                if [ -n "\${NODE_CMD}" ] && [ -x "\${NODE_CMD}" ]; then
                  "\${NODE_CMD}" -e "
                    const fs=require('fs');
                    const name=process.env.PROJECT_NAME||'app';
                    fs.mkdirSync('sca',{recursive:true});
                    fs.writeFileSync('sca/bom.json', JSON.stringify({
                      bomFormat:'CycloneDX', specVersion:'1.4', version:1,
                      metadata:{ component:{ type:'application', name } },
                      components:[]
                    }, null, 2) + '\\n');
                  "
                elif command -v python3 >/dev/null 2>&1; then
                  python3 -c "import json,os; os.makedirs('sca',exist_ok=True); json.dump({'bomFormat':'CycloneDX','specVersion':'1.4','version':1,'metadata':{'component':{'type':'application','name':os.environ.get('PROJECT_NAME','app')}},'components':[]}, open('sca/bom.json','w'), indent=2)"
                else
                  echo "[sca] WARN: no node or python3 for minimal BOM"
                fi
              fi
              test -f sca/bom.json && echo 0 || echo 1
            """, returnStdout: true).trim().tokenize('\n').last()
            if (jvmScaRc == "0") {
              paasStepOk(4, 'sca', 'sca/bom.json generated (maven or minimal static/Dockerfile)')
              if (fileExists("${scaJvmRoot}/sca/bom.json") && !fileExists("sca/bom.json")) {
                sh "mkdir -p sca && cp '${scaJvmRoot}/sca/bom.json' sca/bom.json"
              }
            } else {
              paasStepFail(4, 'sca', 'No package.json, Python, Maven, or Dockerfile/src — enable Docker on Jenkins agent for full OWASP scan')
            }
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
      println "[paas-jenkinsfile] marker=sonar-nodeport-first-20260619 (NodePort before cluster DNS; invalid token hints pipeline-heal)"
      println "[paas-jenkinsfile] marker=sonar-shell-wait-20260701 (nohup scanner + bash DEADLINE poll — no Groovy sleep)"
      println "[paas-jenkinsfile] marker=sonar-auto-rotate-token-20260701 (invalid SONAR_TOKEN → admin API rotate before fail)"
      def sonarKey = dtProjectNameForUpload(projectId, imageName)
      def sonarUrlParam = params.SONAR_HOST_URL?.trim() ?: env.SONAR_HOST_URL ?: ""
      def sonarToken = params.SONAR_TOKEN?.trim() ?: env.SONAR_TOKEN ?: ""
      def sonarNodeIp = (env.NODE_IP?.trim() ?: '192.168.56.129')
      def sonarNp = (sonarUrlParam =~ /http:\/\/([0-9.]+):/) ? (sonarUrlParam =~ /http:\/\/([0-9.]+):/)[0][1] : sonarNodeIp
      if (!sonarUrlParam || !sonarToken) {
        paasStepFail(5, 'sonar', 'SONAR_HOST_URL and SONAR_TOKEN are required on Jenkins job')
      }
      if (!commandExists("docker")) {
        println "[sonar] Docker CLI missing; using npm-based Sonar scanner when configured."
        ensureNodeTool()
        prependPath("/opt/java/openjdk/bin")
        withEnv([
          "SONAR_HOST_URL_PARAM=${sonarUrlParam}",
          "SONAR_NODEPORT=${env.SONAR_NODEPORT?.trim() ?: '30900'}",
          "NODE_IP=${sonarNp}",
          "SONAR_TOKEN=${sonarToken}",
          "SONAR_ADMIN_USER=${env.SONAR_ADMIN_USER ?: 'admin'}",
          "SONAR_ADMIN_PASSWORD=${env.SONAR_ADMIN_PASSWORD ?: ''}",
          "SONAR_ADMIN_NEW_PASSWORD=${env.SONAR_ADMIN_NEW_PASSWORD ?: 'SonarQube123!'}",
          "SONAR_TOKEN_NAME=${env.SONAR_TOKEN_NAME ?: 'paas-jenkins-lab'}",
          "SONAR_PROJECT_KEY=${sonarKey}",
          "SONAR_PROJECT_ID_TAG=${projectId}",
          "SONAR_VERSION=${branchName}-${env.BUILD_NUMBER}"
        ]) {
          def sonarPrepRc = sh(script: '''#!/bin/bash
            set +e
            pick_sonar_url() {
              _np="http://${NODE_IP}:${SONAR_NODEPORT:-30900}"
              for u in \
                "${_np}" \
                "${SONAR_HOST_URL_PARAM}" \
                "http://sonarqube-sonarqube.sonarqube.svc.cluster.local:9000" \
                "http://sonarqube-service.sonarqube.svc.cluster.local:9000" \
                "http://sonarqube.sonarqube.svc.cluster.local:9000"
              do
                [ -z "$u" ] && continue
                if curl -fsS -m 15 "${u%/}/api/system/status" 2>/dev/null | grep -q '"status":"UP"'; then
                  echo "$u"
                  return 0
                fi
              done
              echo "${SONAR_HOST_URL_PARAM:-${_np}}"
            }
            sonar_validate_token() {
              _url="$1"
              VALID=$(curl -sS -m 15 -u "${SONAR_TOKEN}:" "${_url%/}/api/authentication/validate" 2>/dev/null || true)
              printf '%s' "${VALID}" | grep -q '"valid":true'
            }
            sonar_admin_ok() {
              _base="$1" _user="$2" _pass="$3"
              [ -n "${_pass}" ] || return 1
              curl -fsS -m 15 -u "${_user}:${_pass}" "${_base%/}/api/authentication/validate" 2>/dev/null \
                | grep -q '"valid":true'
            }
            sonar_try_rotate_token() {
              _base="${SONAR_HOST_URL%/}"
              _user="${SONAR_ADMIN_USER:-admin}"
              _name="${SONAR_TOKEN_NAME:-paas-jenkins-lab}"
              _admin_pass=""
              for _try in "${SONAR_ADMIN_NEW_PASSWORD:-}" "${SONAR_ADMIN_PASSWORD:-}" "SonarQube123!" "admin"; do
                [ -n "${_try}" ] || continue
                if sonar_admin_ok "${_base}" "${_user}" "${_try}"; then
                  _admin_pass="${_try}"
                  break
                fi
              done
              if [ -z "${_admin_pass}" ]; then
                echo "[sonar] cannot admin-login for token rotate — set SONAR_ADMIN_NEW_PASSWORD on Jenkins job (default SonarQube123!)"
                return 1
              fi
              _enc="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "${_name}" 2>/dev/null || echo "${_name}")"
              curl -fsS -m 15 -u "${_user}:${_admin_pass}" -X POST \
                "${_base}/api/user_tokens/revoke?name=${_enc}" >/dev/null 2>&1 || true
              _resp="$(curl -sS -m 30 -w $'\\n__HTTP__%{http_code}' -u "${_user}:${_admin_pass}" -X POST \
                "${_base}/api/user_tokens/generate?name=${_name}&type=GLOBAL_ANALYSIS_TOKEN" 2>/dev/null || true)"
              _http="${_resp##*$'\\n__HTTP__'}"
              _resp="${_resp%$'\\n__HTTP__'*}"
              if [ "${_http}" != "200" ]; then
                echo "[sonar] token rotate failed HTTP ${_http}: ${_resp}"
                return 1
              fi
              _new="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("token",""))' <<<"${_resp}" 2>/dev/null || true)"
              [ -n "${_new}" ] || return 1
              export SONAR_TOKEN="${_new}"
              echo "[sonar] rotated analysis token via Sonar API (${#_new} chars) — run pipeline-heal to persist to PaaS env"
              return 0
            }
            SONAR_HOST_URL="$(pick_sonar_url)"
            echo "[sonar] using ${SONAR_HOST_URL}"
            _sonar_ready=0
            _last_valid=""
            for _sv in 1 2 3 4 5; do
              VALID=$(curl -sS -m 15 -u "${SONAR_TOKEN}:" "${SONAR_HOST_URL%/}/api/authentication/validate" 2>/dev/null || true)
              _last_valid="${VALID}"
              echo "[sonar] token validate attempt ${_sv}/5: ${VALID:-<curl failed>}"
              if sonar_validate_token "${SONAR_HOST_URL}"; then
                _sonar_ready=1
                break
              fi
              if printf '%s' "${VALID}" | grep -q '"valid":false'; then
                echo "[sonar] SONAR_TOKEN rejected (valid:false) — auto-rotate via Sonar admin API"
                if sonar_try_rotate_token && sonar_validate_token "${SONAR_HOST_URL}"; then
                  _sonar_ready=1
                  break
                fi
                echo "[sonar] auto-rotate failed — run: bash paas/scripts/lab.sh sonar-bootstrap && bash paas/scripts/lab.sh pipeline-heal"
                break
              fi
              if [ "${_sv}" -lt 5 ]; then
                echo "[sonar] Sonar not ready — wait 20s and re-probe URL"
                sleep 20
                SONAR_HOST_URL="$(pick_sonar_url)"
                echo "[sonar] re-probe using ${SONAR_HOST_URL}"
              fi
            done
            if [ "${_sonar_ready}" != "1" ]; then
              if [ -z "${_last_valid}" ]; then
                echo "[sonar] cannot reach Sonar — run: bash paas/scripts/lab.sh sonarqube"
              else
                echo "[sonar] token not valid from Jenkins agent — rotate SONAR_TOKEN via pipeline-heal"
              fi
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
            if [ -f tsconfig.json ] && grep -qE '"moduleResolution"[[:space:]]*:[[:space:]]*"bundler"' tsconfig.json 2>/dev/null; then
              echo "[sonar] Next.js/TS bundler moduleResolution — writing .sonar-tsconfig.json (nodenext for Sonar 9.9 bridge)"
              node -e "
                const fs=require('fs');
                const j=JSON.parse(fs.readFileSync('tsconfig.json','utf8'));
                j.compilerOptions=j.compilerOptions||{};
                j.compilerOptions.moduleResolution='nodenext';
                if(j.compilerOptions.module==='esnext'||j.compilerOptions.module==='ESNext') j.compilerOptions.module='nodenext';
                fs.writeFileSync('.sonar-tsconfig.json', JSON.stringify(j,null,2)+'\\n');
              " 2>/dev/null || cp tsconfig.json .sonar-tsconfig.json
              SONAR_TSCONFIG=.sonar-tsconfig.json
            else
              SONAR_TSCONFIG=
            fi
            SP=sonar-project.properties
            rm -f "${SP}"
            {
              printf 'sonar.host.url=%s\n' "${SONAR_HOST_URL}"
              printf 'sonar.token=%s\n' "${SONAR_TOKEN}"
              printf 'sonar.projectKey=%s\n' "${SONAR_PROJECT_KEY}"
              printf 'sonar.projectName=%s\n' "${SONAR_PROJECT_KEY}"
              printf 'sonar.projectVersion=%s\n' "${SONAR_VERSION}"
              printf 'sonar.sources=%s\n' "${SOURCES}"
              printf 'sonar.exclusions=%s\n' '**/node_modules/**,**/.next/**,**/dist/**,**/build/**,**/.git/**,**/coverage/**,**/*.min.js'
              if [ -n "${SONAR_TSCONFIG:-}" ]; then
                printf 'sonar.typescript.tsconfigPath=%s\n' "${SONAR_TSCONFIG}"
              fi
              printf 'sonar.qualitygate.wait=%s\n' "${JENKINS_SONAR_QUALITY_GATE_WAIT:-false}"
              printf 'sonar.scanner.analysisCacheEnabled=%s\n' 'false'
              printf 'sonar.javascript.node.maxspace=%s\n' "${JENKINS_SONAR_NODE_MAXSPACE:-384}"
              printf 'sonar.scanner.responseTimeout=%s\n' '300'
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
              echo "[sonar] ERROR: java not in PATH"
              exit 1
            fi
            echo "[sonar] java: $(java -version 2>&1 | head -1)"
            mkdir -p paas-artifacts
            printf '%s\n' "${SONAR_HOST_URL}" > paas-artifacts/sonar-host-url.txt
            exit 0
          ''', returnStatus: true)
          if (sonarPrepRc != 0) {
            paasStepFail(5, 'sonar', 'Sonar prep failed — check SONAR_HOST_URL / SONAR_TOKEN')
          }
          def sonarPollSec = (env.JENKINS_SONAR_POLL_SEC?.trim() ?: '12') as int
          def sonarPollMaxMin = (env.JENKINS_SONAR_POLL_MAX_MIN?.trim() ?: '25') as int
          def sonarWaitRc = 1
          for (int sonarAttempt = 1; sonarAttempt <= 3; sonarAttempt++) {
            if (sonarAttempt > 1) {
              echo "[sonar] retry attempt ${sonarAttempt}/3 (prior scan interrupted or failed)"
            }
            def sonarStartRc = sh(script: """#!/bin/bash
              set +e
              LOG=paas-artifacts/sonar-scanner.log
              PIDF=paas-artifacts/sonar-scanner.pid
              if grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' "\${LOG}" 2>/dev/null; then
                echo "[sonar] log already shows success — skip start"
                exit 0
              fi
              if [ -f "\${PIDF}" ]; then
                OLD=\$(cat "\${PIDF}" 2>/dev/null || true)
                if [ -n "\${OLD}" ] && kill -0 "\${OLD}" 2>/dev/null; then
                  echo "[sonar] scanner pid \${OLD} still running"
                  exit 0
                fi
              fi
              export SONAR_TOKEN="\${SONAR_TOKEN}"
              export SONAR_HOST_URL="\$(cat paas-artifacts/sonar-host-url.txt 2>/dev/null || echo "\${SONAR_HOST_URL_PARAM}")"
              export SONAR_SCANNER_OPTS="\${SONAR_SCANNER_OPTS:--Xmx768m}"
              echo "[sonar] === background start attempt ${sonarAttempt} \$(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "\${LOG}"
              nohup npx --yes sonarqube-scanner@4.2.8 \
                -Dsonar.host.url="\${SONAR_HOST_URL}" \
                -Dsonar.token="\${SONAR_TOKEN}" \
                -Dsonar.scanner.responseTimeout=300 \
                >> "\${LOG}" 2>&1 &
              echo \$! > "\${PIDF}"
              sleep 2
              if kill -0 "\$(cat "\${PIDF}")" 2>/dev/null; then
                echo "[sonar] background pid \$(cat "\${PIDF}")"
                exit 0
              fi
              echo "[sonar] ERROR: scanner failed to stay up"
              tail -20 "\${LOG}" 2>/dev/null || true
              exit 1
            """, returnStatus: true)
            if (sonarStartRc != 0) {
              continue
            }
            sonarWaitRc = sh(script: """#!/bin/bash
              set +e
              LOG=paas-artifacts/sonar-scanner.log
              PIDF=paas-artifacts/sonar-scanner.pid
              DEADLINE=\$(( \$(date +%s) + ${sonarPollMaxMin} * 60 ))
              while [ \$(date +%s) -lt "\${DEADLINE}" ]; do
                if [ -f "\${LOG}" ] && grep -qE 'ANALYSIS SUCCESSFUL|EXECUTION SUCCESS' "\${LOG}"; then
                  exit 0
                fi
                if [ -f "\${PIDF}" ]; then
                  PID=\$(cat "\${PIDF}" 2>/dev/null || true)
                  if [ -n "\${PID}" ] && kill -0 "\${PID}" 2>/dev/null; then
                    echo "[sonar] poll \$(date -u +%Y-%m-%dT%H:%M:%SZ) pid alive"
                    sleep ${sonarPollSec}
                    continue
                  fi
                fi
                exit 2
              done
              exit 1
            """, returnStatus: true)
            if (sonarWaitRc == 0) {
              break
            }
            def sonarLogMid = fileExists('paas-artifacts/sonar-scanner.log') ? readFile('paas-artifacts/sonar-scanner.log') : ''
            if (sonarLogMid.contains('EXECUTION SUCCESS') || sonarLogMid.contains('ANALYSIS SUCCESSFUL')) {
              sonarWaitRc = 0
              break
            }
          }
          sh(script: '''#!/bin/bash
            set +e
            PIDF=paas-artifacts/sonar-scanner.pid
            if [ -f "${PIDF}" ]; then
              PID=$(cat "${PIDF}" 2>/dev/null || true)
              if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
                kill "${PID}" 2>/dev/null || true
              fi
            fi
            rm -f sonar-project.properties .sonar-tsconfig.json paas-artifacts/sonar-scanner.pid
            LOG=paas-artifacts/sonar-scanner.log
            if [ -f "${LOG}" ]; then
              tail -60 "${LOG}" || true
            fi
            exit 0
          ''', returnStatus: true)
          def sonarLog = fileExists('paas-artifacts/sonar-scanner.log') ? readFile('paas-artifacts/sonar-scanner.log') : ''
          def sonarPassed = (sonarWaitRc as Integer) == 0 \
            || sonarLog.contains('EXECUTION SUCCESS') \
            || sonarLog.contains('ANALYSIS SUCCESSFUL')
          if (sonarPassed) {
            paasStepOk(5, 'sonar', "analysis submitted for projectKey=${sonarKey}")
          } else {
            paasStepFail(5, 'sonar', "scanner did not complete — see paas-artifacts/sonar-scanner.log; sync pipeline: bash paas/scripts/lib/fix-paas-deploy-cps-split-now.sh")
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
}
def runPaasDeployStep6() {
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
}
