// STAGES_BUNDLE_VERSION=helm-portable-20260620-cps-split
// CPS_LOAD_METHOD_SYNTAX=20260626
def runPaasDeploySteps7_8() {
  stage("Step 7 — Packaging du chart Helm") {
    nonFatalStage("7. Packaging du chart Helm (aligné Jenkinsfile.paas-deploy.full)") {
      def helmBin = ensureHelmTool()
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
      if (fileExists("Chart.yaml")) {
        sh "mkdir -p paas-artifacts/helm && '${helmBin}' package . --destination paas-artifacts/helm"
        println "[helm] Chart packagé : paas-artifacts/helm/*.tgz (déploiement Kubernetes via Helm / GitOps)."
      } else {
        def safeName = (imageName.tokenize('/').last()?.replaceAll(/[^a-zA-Z0-9.-]/, '-') ?: 'paas-app').replaceAll(/\.+/, '-')
        sh """
          set -eu
          mkdir -p paas-artifacts/helm-stub/templates paas-artifacts/helm
          cat > paas-artifacts/helm-stub/Chart.yaml <<EOF
apiVersion: v2
name: ${safeName}
description: PaaS lab stub chart (GitOps chart lives in PaaS repo)
type: application
version: 0.1.${env.BUILD_NUMBER}
appVersion: "${branchName}-${env.BUILD_NUMBER}"
EOF
          cat > paas-artifacts/helm-stub/values.yaml <<EOF
image:
  repository: ${artifactImage.tokenize(':')[0]}
  tag: ${artifactImage.contains(':') ? artifactImage.tokenize(':')[1] : 'latest'}
projectId: ${projectId}
EOF
          cat > paas-artifacts/helm-stub/templates/placeholder.yaml <<EOF
# Stub — real manifests applied by PaaS GitOps after PAAS_BUILD_COMPLETE
EOF
          '${helmBin}' package paas-artifacts/helm-stub --destination paas-artifacts/helm
        """
        println "[helm] Stub chart packagé (no Chart.yaml in app repo) → paas-artifacts/helm/*.tgz for Step 11 OCI push."
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
        paasStepWarn(8, 'artifactory', 'ARTIFACTORY_URL missing — skip (lab: bash paas/scripts/lab.sh artifactory-bootstrap)')
      } else {
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
        paasStepWarn(8, 'artifactory', 'ARTIFACTORY_USERNAME+PASSWORD or ARTIFACTORY_ACCESS_TOKEN missing — skip (lab: bash paas/scripts/lab.sh artifactory-bootstrap)')
      }
      if (credId || bearer || (basicUser && basicPass)) {
        paasStepOk(8, 'artifactory', "published to ${artiBase}")
      }
    }
    }
    }
  }
}
def runPaasDeploySteps9_12() {
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
        paasStepWarn(10, 'zap', 'ZAP_TARGET_URL missing — skip (set APP_BASE_URL in PaaS)')
      } else {
      println "[zap] Cible DAST: ${zapTarget}"
      def jh = (env.JENKINS_HOME ?: '/var/jenkins_home').trim()
      if (jh) {
        prependPath("${jh}/bin")
      }
      withEnv(["ZAP_TARGET=${zapTarget}", "ZAP_BUILD=${env.BUILD_NUMBER}"]) {
        def zapRc = sh(script: '''#!/bin/bash
          set +e
          mkdir -p paas-artifacts
          run_zap_docker() {
            docker run --rm \
              -v "$PWD/paas-artifacts:/zap/wrk/:rw" \
              ghcr.io/zaproxy/zaproxy:stable \
              zap-baseline.py -t "$ZAP_TARGET" \
                -r /zap/wrk/zap-baseline-report.html \
                -J /zap/wrk/zap-baseline-report.json
          }
          run_zap_kubectl() {
            local ns="${ZAP_K8S_NAMESPACE:-cicd}" pod="paas-zap-${ZAP_BUILD:-0}"
            local kctl="${JENKINS_KUBECTL_BIN:-${JENKINS_HOME:-/var/jenkins_home}/bin/kubectl}"
            command -v kubectl >/dev/null 2>&1 && kctl=kubectl
            [ -x "$kctl" ] || { echo "[zap] kubectl missing at $kctl"; return 127; }
            "$kctl" delete pod -n "$ns" "$pod" --ignore-not-found --wait=false 2>/dev/null || true
            "$kctl" run "$pod" -n "$ns" --restart=Never --image=ghcr.io/zaproxy/zaproxy:stable \
              --command -- zap-baseline.py -t "$ZAP_TARGET" -J /tmp/zap.json -r /tmp/zap.html 2>/dev/null
            "$kctl" wait -n "$ns" --for=condition=Ready "pod/$pod" --timeout=180s 2>/dev/null || true
            sleep 5
            "$kctl" logs -n "$ns" "$pod" > paas-artifacts/zap-baseline-pod.log 2>&1 || true
            "$kctl" exec -n "$ns" "$pod" -- cat /tmp/zap.json > paas-artifacts/zap-baseline-report.json 2>/dev/null || true
            "$kctl" exec -n "$ns" "$pod" -- cat /tmp/zap.html > paas-artifacts/zap-baseline-report.html 2>/dev/null || true
            "$kctl" delete pod -n "$ns" "$pod" --ignore-not-found --wait=false 2>/dev/null || true
          }
          if command -v docker >/dev/null 2>&1; then
            echo "[zap] using docker"
            run_zap_docker
          elif command -v kubectl >/dev/null 2>&1 || [ -x "\${JENKINS_HOME:-/var/jenkins_home}/bin/kubectl" ]; then
            KCTL="\${JENKINS_KUBECTL_BIN:-}"
            if [ -z "\${KCTL}" ] || [ ! -x "\${KCTL}" ]; then
              KCTL="\${JENKINS_HOME:-/var/jenkins_home}/bin/kubectl"
            fi
            if [ ! -x "\${KCTL}" ] && command -v kubectl >/dev/null 2>&1; then
              KCTL=kubectl
            fi
            export JENKINS_KUBECTL_BIN="\${KCTL}"
            echo "[zap] docker CLI absent — using kubectl at \${KCTL} (lab fallback)"
            run_zap_kubectl
          else
            echo "[zap] docker and kubectl absent — install: bash paas/scripts/lab.sh jenkins-zap-tools"
            exit 127
          fi
          echo "[zap] zap-baseline exit code: $? (0=pass, 1=fail, 2=warnings) — stage non-bloquante"
        ''', returnStatus: true)
        if (zapRc != 0) {
          println "[zap] WARN: zap runner exit ${zapRc} (non-blocking)"
        }
      }
      if (fileExists('paas-artifacts/zap-baseline-report.html')) {
        paasStepOk(10, 'zap', 'ZAP report in paas-artifacts/')
      } else {
        paasStepWarn(10, 'zap', 'ZAP baseline produced no report — install: bash paas/scripts/lab.sh jenkins-zap-tools')
      }
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
        paasStepFail(11, 'helm_oci', 'HARBOR_REGISTRY / HARBOR_USERNAME / HARBOR_PASSWORD required')
      }
      def helmBin = ensureHelmTool()
      if (!fileExists("paas-artifacts/helm")) {
        paasStepFail(11, 'helm_oci', 'paas-artifacts/helm missing — Step 7 must package a chart first')
      }
      def regHost = reg.replaceFirst("^https?://", "").replaceAll(/\/$/, "")
      def ociRef = "oci://${regHost}/${ociProj}"
      withEnv(["HELM_OCI_REF=${ociRef}", "REG_HOST=${regHost}", "HELM_BIN=${helmBin}"]) {
        sh '''
          set +e
          LOGIN_OPTS=""
          if [ "${HELM_OCI_INSECURE:-true}" = "true" ]; then LOGIN_OPTS="--insecure"; fi
          PUSH_OPTS=""
          if [ "${HELM_OCI_PLAIN_HTTP:-true}" = "true" ]; then PUSH_OPTS="--plain-http"; fi
          chart_count=0
          for f in paas-artifacts/helm/*.tgz; do
            [ -f "$f" ] || continue
            chart_count=$((chart_count + 1))
          done
          if [ "${chart_count}" -eq 0 ]; then
            echo "[helm-oci] Aucun chart .tgz à publier."
            exit 1
          fi
          echo "${HARBOR_PASSWORD}" | "${HELM_BIN}" registry login ${LOGIN_OPTS} "${REG_HOST}" -u "${HARBOR_USERNAME}" --password-stdin || exit 1
          for f in paas-artifacts/helm/*.tgz; do
            [ -f "$f" ] || continue
            echo "[helm-oci] helm push $f ${HELM_OCI_REF}"
            "${HELM_BIN}" push ${PUSH_OPTS} "$f" "${HELM_OCI_REF}" || exit 1
          done
        '''
      }
      paasStepOk(11, 'helm_oci', "Helm OCI push OK → ${ociRef}")
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
}
def runPaasDeploy() {
  runPaasDeployEnvInit()
  runPaasDeploySteps1_2()
  runPaasDeployStep3()
  runPaasDeploySteps4_5()
  runPaasDeployStep6()
  runPaasDeploySteps7_8()
  runPaasDeploySteps9_12()
}
// CPS_ORCHESTRATOR=runPaasDeploy-after-all-loads (job wrapper calls runPaasDeploy() — not inside load p3)
