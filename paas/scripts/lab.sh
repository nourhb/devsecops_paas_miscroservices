#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${DIR}/lib"
REPO_ROOT="$(cd "${DIR}/../.." && pwd)"
cmd="${1:-}"
cmd="${cmd//$'\r'/}"

_run_boot_script() {
  local action="$1"
  local lab_user="${SUDO_USER:-${USER:-master}}"
  if [[ "$(id -u)" -eq 0 ]]; then
    PAAS_REPO_DIR="${REPO_ROOT}" PAAS_LAB_USER="${lab_user}" bash "$LIB/install-paas-boot-service.sh" "${action}"
  elif [[ "${action}" == "status" ]]; then
    PAAS_REPO_DIR="${REPO_ROOT}" bash "$LIB/install-paas-boot-service.sh" status
  else
    sudo env PAAS_REPO_DIR="${REPO_ROOT}" PAAS_LAB_USER="${lab_user}" bash "$LIB/install-paas-boot-service.sh" "${action}"
  fi
}
usage() {
  echo "usage: lab.sh <command>"
  echo "  start     Recover PaaS after reboot (postgres + frontend-force + health)"
  echo "  boot-install  Install systemd auto-start on VM boot (run once with sudo)"
  echo "  boot-enable   One command: install boot service + test recover (no reboot yet)"
  echo "  boot-fix      Install boot service + kubeconfig + recover now (after VM reboot)"
  echo "  boot-status   Show paas-lab-start.service + boot log tail"
  echo "  bootstrap Harbor/Kyverno cosign bootstrap"
  echo "  harbor    Recover Harbor registry (502 / crane failures)"
  echo "  db-repair Fix frontend -> Postgres TCP connectivity"
  echo "  postgres    Deploy/wait/schema for in-cluster Postgres"
  echo "  health    Quick health check"
  echo "  prometheus  Restart/wait for Prometheus endpoints in monitoring"
  echo "  probe-prometheus  Diagnose Prometheus connectivity from frontend pod"
  echo "  probe-k8s     Diagnose Kubernetes API from frontend pod (UI cluster pages)"
  echo "  fix-k8s-ui    Strip bad KUBE_CONFIG_PATH + sync env (+ REBUILD=1 for image fix)"
  echo "  monitoring-disk  Safe disk cleanup (no docker prune -af) + stale pods"
  echo "                   Use: monitoring-disk quick — skip slow cluster-wide image pulls"
  echo "  guard         Full lab hardening check (disk, images, Prometheus, health)"
  echo "  guard-cron    Show/install auto-heal cron (watchdog 10m + guard 6h)"
  echo "  watchdog      Lightweight auto-heal (disk, kyverno, postgres, storms)"
  echo "  harden        One-shot: unpin frontend, db-repair, cron, health"
  echo "  env       Sync docker-compose.env to the frontend pod"
  echo "  env-quick Sync env only (skip Dependency-Track — use when k8s API is slow)"
  echo "  jenkins   Sync Jenkinsfile + rebuild PaaS frontend image"
  echo "  jenkins-stages  Render + install CPS-split load bundles (no frontend rebuild)"
  echo "  fix-paas-deploy Fix MethodTooLarge: CPS bundles + API job wrapper (break loop)"
  echo "  force-fix-paas-deploy  fix-paas-deploy + disable UI job revert + restart frontend"
  echo "  break-paas-deploy-loop  Same as fix-paas-deploy (explicit name)"
  echo "  jenkins-tools   Pre-install helm + crane under JENKINS_HOME on Jenkins pod"
  echo "  sonarqube       Restart SonarQube if NodePort :30900 is not UP"
  echo "  sonar-bootstrap   Fix admin password loop + create SONAR_TOKEN via API (no UI)"
  echo "  artifactory-bootstrap  Deploy JFrog Artifactory OSS + wire ARTIFACTORY_* (Step 8)"
  echo "  full-pipeline-enable   Steps 7-8+10-11 no-skip: helm, Artifactory, ZAP, Helm OCI"
  echo "  jenkins-zap-tools   kubectl in Jenkins pod + RBAC for Step 10 ZAP"
  echo "  jenkins-bootstrap  Create JENKINS_API_TOKEN after fresh Jenkins install (no UI)"
  echo "  jenkins-auth       Fix JENKINS_USERNAME+token in .env (env-quick reads .env, not docker-compose.env)"
  echo "  jenkins-create-job  Create paas-deploy job + CPS bundle (fresh Jenkins)"
  echo "  jenkins-plugins  Install workflow-aggregator (required after jenkins-install)"
  echo "  jenkins-install  Helm install/repair Jenkins (:30090, no plugin download)"
  echo "  jenkins-recover  Restart Jenkins in cicd + wait for endpoints"
  echo "  jenkins-build-safe  Raise Jenkins memory + relax probes (Sonar/Next build stability)"
  echo "  sync-repo       git fetch + reset --hard origin/main (fix VM drift blocking git pull)"
  echo "  fix-sonar-step5 sync-repo + jenkins-build-safe + push checkpoint-poll pipeline to Jenkins"
  echo "  jenkins-pvc-backup  Tar jobs/plugins/paas BEFORE PVC wipe (check Released PVs)"
  echo "  fix-jenkins-dedupe  Remove duplicate runPaasDeploy() in stages monolith (host python3)"
  echo "  restore-paas-deploy One-shot: render monolith + job wrapper + verify"
  echo "  jenkins-fix-executors  Set built-in numExecutors (fix 'Waiting for next available executor')"
  echo "  assemble-monolith  Rebuild paas-deploy-stages.groovy from 7 split files (closure->method, +helpers)"
  echo "  dependency-track  Heal DT API server + sync NodePort URL in env"
  echo "  dt-bootstrap      Fix DT login 405 + create API key via CLI (no UI)"
  echo "  argocd-bootstrap  Set ARGOCD_BASE_URL + admin password in env (no UI)"
  echo "  integrations-bootstrap  Wire Grafana/Trivy/DT URLs + scale monitoring stack"
  echo "  frontend-heal     Restore UI :30100 (pins master for recovery image)"
  echo "  frontend-force    RS cleanup + pin recovery image when rollout hangs"
  echo "  frontend-stop     Scale frontend to 0 + pause (stop eviction storm)"
  echo "  frontend-safety   Recreate + master pin (prevent pod storms)"
  echo "  emergency       Kyverno webhook unblock + disk + restore PaaS UI"
  echo "  emergency-up    Unstick everything: kill lab jobs, restart k3s, recover UI"
  echo "  quick-up        ONE command: master + postgres + frontend UI (use this first)"
  echo "  reboot          Safe recovery after VM/PC reboot (fixes broken deployment images)"
  echo "  reinstall-platform  Reinstall Jenkins+Harbor+Argo after k3s db wipe (~30-60 min)"
  echo "  fresh-cluster   Full redeploy after k3s db wipe (namespace + postgres + UI :30100)"
  echo "  k3s-vacuum      Fix k3s stuck activating (slow SQLite — run with sudo)"
  echo "  k3s-ensure      Wait for / restart k3s API when 127.0.0.1:6443 times out"
  echo "  break-loop      STOP cron + pause frontend + break db-repair loop"
  echo "  worker2         Heal worker2 NotReady (Postgres PVC node)"
  echo "  master-heal     Heal master NotReady (PaaS UI runs on master)"
  echo "  frontend  Rebuild and roll out PaaS frontend image only"
  echo "  frontend-rollout  Roll out existing local/recovery image (no rebuild)"
  echo "  repair-frontend-ui  Fix UI 500 after rollout (restore envFrom + probes)"
  echo "  repair    Rebuild GitOps Helm chart (fix invalid K8s names)"
  echo "  fix-gitops  Abort rebase and reset ~/gitops to origin/main"
  echo "  heal      Patch GitOps values + Argo sync + rollout"
  echo "  deploy    git pull + Kyverno Audit + cosign try + heal (one-shot)"
  echo "  ultimate  Full fix: Kyverno HTTP Harbor + GitOps + deploy (one command)"
  echo "  restore   Jenkins + frontend env + pipeline (get deploy working again)"
  echo "  rollback-june17  Restore Jenkins pipeline to 17 Jun build #756 layout (bb1fef3)"
  echo "  pipeline-heal  Full 12-step pipeline: Sonar token + env + Jenkins + Harbor"
}
case "$cmd" in
  start|recover)
    bash "$LIB/recover-paas-after-k3s-restart.sh" ;;
  boot-install|install-boot)
    _run_boot_script install ;;
  boot-enable|enable-boot)
    bash "$LIB/lab-boot-enable.sh" ;;
  boot-fix|fix-boot)
    bash "$LIB/lab-boot-fix.sh" ;;
  boot-status|boot-log)
    _run_boot_script status ;;
  boot-uninstall)
    _run_boot_script uninstall ;;
  bootstrap)
    bash "$LIB/lab-kyverno.sh" bootstrap ;;
  harbor)
    bash "$LIB/lab-harbor.sh" recover ;;
  db-repair)
    bash "$LIB/lab-paas-db-repair.sh" ;;
  postgres)
    bash "$LIB/lab-postgres.sh" "${2:-all}" ;;
  health|check)
    bash "$LIB/check-paas-lab-health.sh" ;;
  prometheus|prom)
    bash "$LIB/lab-prometheus-recover.sh" ;;
  probe-prometheus)
    bash "$LIB/probe-prometheus-lab.sh" ;;
  probe-k8s|k8s-probe)
    bash "$LIB/probe-k8s-lab.sh" ;;
  fix-k8s-ui|k8s-ui)
    bash "$LIB/fix-k8s-ui-lab.sh" ;;
  monitoring-disk|disk-heal)
    bash "$LIB/lab-monitoring-disk-heal.sh" "${2:-}" ;;
  disk-emergency|free-disk)
    bash "$LIB/lab-disk-emergency-free.sh" ;;
  frontend-minimal|minimal-frontend)
    bash "$LIB/lab-frontend-minimal-deploy.sh" ;;
  guard)
    bash "$LIB/lab-guard.sh" ;;
  guard-cron)
    bash "$LIB/lab-guard-cron.sh" "${2:-show}" ;;
  watchdog|watch)
    bash "$LIB/lab-watchdog.sh" ;;
  harden|fortify)
    bash "$LIB/lab-harden.sh" ;;
  env|env-quick)
    bash "$LIB/sync-cosign-public-key-env.sh" || true
    bash "$LIB/compose-paas-frontend-env.sh"
    if [[ "$cmd" == "env-quick" ]] || [[ "${PAAS_SKIP_DT:-}" == "1" ]]; then
      echo "SKIP: Dependency-Track (env-quick / PAAS_SKIP_DT=1)"
    else
      LAB_DT_ENV_ONLY=true bash "$LIB/lab-dependency-track.sh" || true
    fi
    bash "$LIB/sync-paas-frontend-env-k8s.sh" ;;
  jenkins)
    LAB_DT_SKIP_HEAL="${LAB_DT_SKIP_HEAL:-true}" bash "$LIB/sync-jenkins-pipeline-from-repo.sh" ;;
  jenkins-stages|stages)
    bash "$LIB/install-jenkins-stages-file.sh" ;;
  fix-cps-load|fix-load-syntax|cps-load-method)
    bash "$LIB/fix-cps-load-method-syntax.sh" ;;
  fix-p3-self-invoke|fix-p3-invoke)
    bash "$LIB/fix-p3-no-self-invoke.sh" ;;
  fix-paas-deploy|cps-split|fix-method-too-large|break-paas-deploy-loop)
    bash "$LIB/fix-paas-deploy-stages-load.sh" ;;
  force-fix-paas-deploy|force-fix)
    bash "$LIB/restore-paas-deploy-working.sh" ;;
  force-api-paas-deploy|api-wrapper-now)
    bash "$LIB/force-api-jenkins-paas-deploy-now.sh" ;;
  apply-inline-wrapper|inline-wrapper)
    bash -c 'set -a; source paas/frontend/docker-compose.env 2>/dev/null; set +a; exec python3 paas/scripts/lib/apply-jenkins-inline-steps-wrapper.py' ;;
  jenkins-tools|agent-tools)
    bash "$LIB/lab-jenkins-agent-tools.sh" ;;
  sonarqube|sonar-heal|sonar-recover)
    bash "$LIB/lab-sonarqube-recover.sh" ;;
  sonar-bootstrap|bootstrap-sonar)
    bash "$LIB/bootstrap-sonarqube-lab.sh" ;;
  artifactory-bootstrap|bootstrap-artifactory|artifactory)
    bash "$LIB/bootstrap-artifactory-lab.sh" ;;
  full-pipeline-enable|enable-full-pipeline|no-skip)
    bash "$LIB/lab-enable-full-pipeline.sh" ;;
  jenkins-zap-tools|zap-tools)
    bash "$LIB/lab-jenkins-zap-tools.sh" ;;
  jenkins-bootstrap|bootstrap-jenkins)
    bash "$LIB/lab-jenkins-bootstrap.sh" ;;
  jenkins-auth|jenkins-sync-auth|fix-jenkins-auth)
    bash "$LIB/lab-jenkins-sync-auth.sh" ;;
  jenkins-create-job|create-paas-deploy)
    bash "$LIB/jenkins-create-paas-deploy-now.sh" ;;
  jenkins-plugins|pipeline-plugins)
    bash "$LIB/install-jenkins-workflow-plugins.sh" 2>/dev/null || bash "$LIB/lab-jenkins-pipeline-plugins.sh" ;;
  jenkins-install|install-jenkins)
    bash "$LIB/lab-jenkins-helm-install.sh" install ;;
  jenkins-fix-init|fix-jenkins-init)
    bash "$LIB/lab-jenkins-helm-install.sh" repair ;;
  jenkins-recover|recover-jenkins)
    bash "$LIB/lab-jenkins-recover.sh" recover ;;
  jenkins-build-safe|jenkins-stability|build-safe)
    bash "$LIB/lab-jenkins-build-safe.sh" ;;
  sync-repo|git-sync|lab-git-sync)
    bash "$LIB/lab-git-sync-origin.sh" ;;
  deploy-fix-sonar|fix-sonar-step5)
    bash "$LIB/lab-git-sync-origin.sh"
    bash "$LIB/lab-jenkins-build-safe.sh" || echo "WARN: jenkins-build-safe failed — continuing pipeline sync"
    rm -rf paas/jenkins/.render-test /var/tmp/paas-deploy-bundle
    bash "$LIB/fix-paas-deploy-cps-split-now.sh"
    kubectl exec -n "${JENKINS_K8S_NAMESPACE:-cicd}" jenkins-0 -c jenkins --request-timeout=60s -- \
      grep -c 'sonar-checkpoint-poll-20260630' /var/jenkins_home/paas/paas-deploy-stages.groovy \
      | tr -d '\r\n' | grep -qx 1 && echo "OK: sonar-checkpoint-poll on pod" \
      || { echo "FAIL: pod missing sonar-checkpoint-poll" >&2; exit 1; } ;;
  jenkins-pvc-backup|backup-jenkins-pvc)
    bash "$LIB/lab-jenkins-pvc-backup.sh" ;;
  fix-jenkins-dedupe|jenkins-dedupe)
    bash "$LIB/fix-jenkins-stages-dedupe.sh" ;;
  restore-paas-deploy|restore-paas-deploy-working)
    bash "$LIB/restore-paas-deploy-working.sh" ;;
  jenkins-fix-executors|fix-jenkins-executors|executors)
    bash "$LIB/lab-jenkins-fix-executors.sh" ;;
  assemble-monolith|fix-monolith|jenkins-monolith)
    bash "$LIB/assemble-paas-deploy-monolith.sh" ;;
  dependency-track|dtrack)
    bash "$LIB/lab-dependency-track.sh" ;;
  dt-bootstrap|dependency-track-bootstrap)
    bash "$LIB/bootstrap-dependency-track-lab.sh" ;;
  argocd-bootstrap|bootstrap-argocd)
    bash "$LIB/bootstrap-argocd-lab.sh" ;;
  integrations-bootstrap|bootstrap-integrations)
    bash "$LIB/bootstrap-integrations-lab.sh" ;;
  frontend-heal)
    bash "$LIB/lab-frontend-schedule-heal.sh" ;;
  frontend-unstick|unstick-frontend)
    bash "$LIB/lab-frontend-rollout-unstick.sh" ;;
  frontend-recover)
    bash "$LIB/lab-frontend-recover.sh" ;;
  frontend-stop|stop-storm)
    bash "$LIB/lab-frontend-stop-storm.sh" ;;
  frontend-safety|safety)
    bash "$LIB/lab-frontend-lab-safety.sh" apply ;;
  frontend-force|force-frontend)
    bash "$LIB/lab-frontend-force-recover.sh" ;;
  emergency|unblock)
    bash "$LIB/lab-emergency-unblock.sh" ;;
  emergency-up|unstick|stuck)
    bash "$LIB/lab-emergency-up.sh" ;;
  quick-up|up|fix)
    bash "$LIB/lab-quick-up.sh" ;;
  fresh-cluster|bootstrap-lab|rebuild-lab)
    bash "$LIB/lab-fresh-cluster.sh" ;;
  reboot|reboot-recover|after-reboot)
    bash "$LIB/lab-reboot-recover.sh" ;;
  reinstall-platform|platform-reinstall|reinstall)
    bash "$LIB/lab-reinstall-platform.sh" ;;
  k3s-vacuum|vacuum-k3s|k3s-db)
    if [[ "$(id -u)" -eq 0 ]]; then
      bash "$LIB/lab-k3s-db-vacuum.sh"
    else
      sudo bash "$LIB/lab-k3s-db-vacuum.sh"
    fi ;;
  k3s-ensure|k3s)
    bash "$LIB/lab-k3s-ensure.sh" ;;
  restore|fix-app|back)
    bash "$LIB/lab-restore-app.sh" ;;
  rollback-june17|june17|rollback-756)
    bash "$LIB/lab-rollback-june17.sh" ;;
  pipeline-heal|pipeline|12steps|full-pipeline)
    bash "$LIB/lab-pipeline-full-heal.sh" ;;
  break-loop|stop-loop|break)
    bash "$LIB/lab-break-loop.sh" ;;
  worker2|worker2-heal)
    bash "$LIB/lab-worker2-heal.sh" ;;
  master-heal|master)
    bash "$LIB/lab-master-heal.sh" ;;
  frontend)
    bash "$LIB/rebuild-paas-frontend-lab.sh" ;;
  frontend-rollout|rollout-frontend)
    bash "$LIB/rollout-paas-frontend-recovery.sh" ;;
  repair-frontend-ui|fix-ui-500)
    bash "$LIB/repair-frontend-ui-500.sh" ;;
  repair)
    bash "$LIB/repair-gitops-app-lab.sh" "${2:?usage: lab.sh repair <project-slug> [tag]}" "${3:-655}" ;;
  fix-gitops)
    source "$LIB/gitops-lab-lib.sh"
    gitops_fix_repo_lab ;;
  heal)
    bash "$DIR/heal-project-deploy-lab.sh" "${2:?usage: lab.sh heal <project-slug> <build> [port]}" "${3:?}" "${4:-3000}" ;;
  deploy)
    REPO_ROOT="$(cd "$DIR/../.." && pwd)"
    git -C "${REPO_ROOT}" pull origin main 2>/dev/null || true
    export COSIGN_LAB_ENFORCE_SIGNED="${COSIGN_LAB_ENFORCE_SIGNED:-false}"
    bash "$LIB/lab-kyverno.sh" apply
    bash "$LIB/ensure-harbor-nipio-cosign-lab.sh" "${2:?usage: lab.sh deploy <project-slug> <build> [port]}" "${3:?}" || true
    bash "$DIR/heal-project-deploy-lab.sh" "${2}" "${3}" "${4:-3000}" ;;
  ultimate)
    PROJECT_NAME="${2:?usage: lab.sh ultimate <project-slug> <build> [port]}"
    TAG="${3:?usage: lab.sh ultimate <project-slug> <build> [port]}"
    TARGET_PORT="${4:-3000}"
    NODE_IP="${NODE_IP:-192.168.56.129}"
    APP="paas-${PROJECT_NAME}"
    NS="${PROJECT_NAME}"
    URL="http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"
    echo "=============================================="
    echo " Ultimate deploy: ${PROJECT_NAME} :${TAG} :${TARGET_PORT}"
    echo " URL: ${URL}"
    echo "=============================================="
    bash "$LIB/lab-harbor.sh" recover || true
    source "$LIB/gitops-lab-lib.sh"
    gitops_fix_repo_lab
    bash "$LIB/repair-gitops-app-lab.sh" "${PROJECT_NAME}" "${TAG}"
    bash "$LIB/lab-kyverno.sh" apply
    bash "$LIB/ensure-harbor-nipio-cosign-lab.sh" "${PROJECT_NAME}" "${TAG}"
    bash "$DIR/heal-project-deploy-lab.sh" "${PROJECT_NAME}" "${TAG}" "${TARGET_PORT}"
    echo ""
    echo "=============================================="
    HTTP="$(curl -s -o /dev/null -w '%{http_code}' "${URL}" 2>/dev/null || echo '?')"
    echo "HTTP ${URL} => ${HTTP}"
    kubectl get application "${APP}" -n argocd 2>/dev/null || true
    kubectl get deploy,pods -n "${NS}" 2>/dev/null || true
    if [[ "${HTTP}" =~ ^[23] ]]; then
      echo "OK — app is up"
    else
      echo "Diagnostics:"
      echo "  kubectl describe application ${APP} -n argocd | tail -25"
      echo "  kubectl get events -n ${NS} --sort-by=.lastTimestamp | tail -15"
    fi
    echo "=============================================="
    ;;
  ""|-h|--help|help)
    usage
    exit 0 ;;
  *)
    echo "unknown: $cmd" >&2
    usage
    exit 1 ;;
esac

