// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626
agentLabel = params.JENKINS_AGENT_LABEL?.trim() ?: ""
branchName = params.BRANCH?.trim() ?: "main"
gitUrl = params.GIT_URL?.trim() ?: ""
imageName = params.IMAGE_NAME?.trim() ?: ""
projectId = params.PROJECT_ID?.trim() ?: ""
gitCredentialsId = params.GIT_CREDENTIALS_ID?.trim() ?: ""
artifactImage = ""
dockerAvailable = false
imagePushPending = false
imagePublishedViaCrane = false
cosignImageRef = ""


def runPaasDeployEnvInit() {
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
  env.SONAR_ADMIN_USER = (params.SONAR_ADMIN_USER?.trim() ?: env.SONAR_ADMIN_USER ?: "admin").trim()
  env.SONAR_ADMIN_PASSWORD = (params.SONAR_ADMIN_PASSWORD?.trim() ?: env.SONAR_ADMIN_PASSWORD ?: "").trim()
  env.SONAR_ADMIN_NEW_PASSWORD = (params.SONAR_ADMIN_NEW_PASSWORD?.trim() ?: env.SONAR_ADMIN_NEW_PASSWORD ?: "SonarQube123!").trim()
  env.SONAR_TOKEN_NAME = (params.SONAR_TOKEN_NAME?.trim() ?: env.SONAR_TOKEN_NAME ?: "paas-jenkins-lab").trim()
  env.NVD_API_KEY = (params.NVD_API_KEY?.trim() ?: env.NVD_API_KEY ?: "").trim()
  env.JENKINS_DEPENDENCY_TRACK_BASE_URL = (params.JENKINS_DEPENDENCY_TRACK_BASE_URL?.trim() ?: env.JENKINS_DEPENDENCY_TRACK_BASE_URL ?: "").trim()
  env.DEPENDENCY_TRACK_BASE_URL = (params.DEPENDENCY_TRACK_BASE_URL?.trim() ?: env.DEPENDENCY_TRACK_BASE_URL ?: "").trim()
  if (!env.JENKINS_DEPENDENCY_TRACK_BASE_URL?.trim() && env.DEPENDENCY_TRACK_BASE_URL?.trim()) {
    env.JENKINS_DEPENDENCY_TRACK_BASE_URL = env.DEPENDENCY_TRACK_BASE_URL.trim()
  }
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
  env.HELM_OCI_INSECURE = (params.HELM_OCI_INSECURE?.trim() ?: env.HELM_OCI_INSECURE ?: "true").trim()
  env.HELM_OCI_PLAIN_HTTP = (params.HELM_OCI_PLAIN_HTTP?.trim() ?: env.HELM_OCI_PLAIN_HTTP ?: "true").trim()
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
  println '[paas-jenkinsfile] marker=harbor-crane-dual-auth-20260630 (IP+nip.io login; IP fallback on 401 push)'
  println '[paas-jenkinsfile] marker=harbor-ensure-push-token-20260630 (API ensure paas project + JWT push scope before crane append)'
  println '[paas-jenkinsfile] marker=harbor-rbac-jwt-push-20260701 (fail Step6 when token actions lack push — run fix-harbor-push-now.sh)'
  println '[paas-jenkinsfile] marker=dt-nodeport-first-20260619 (DT/Sonar NodePort before cluster DNS on built-in agent)'
  println '[paas-jenkinsfile] marker=helm-portable-20260619 (ensureHelmTool cached; stub chart Step 7; OCI push Step 11; ZAP kubectl fallback)'
  println '[paas-jenkinsfile] marker=sca-python-portable-yarn-install-20260630 (ensurePythonTool; yarn install before cyclonedx; minimal BOM for *.py)'
  println '[paas-jenkinsfile] marker=sca-python-node-first-20260630 (Node requirements.txt BOM — no python3 required on agent)'
}
