#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${DIR}/lib"
cmd="${1:-}"
usage() {
  echo "usage: lab.sh <command>"
  echo "  start     Recover PaaS after reboot (postgres + frontend-force + health)"
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
  echo "  jenkins-recover  Restart Jenkins in cicd + wait for endpoints"
  echo "  dependency-track  Heal DT API server + sync NodePort URL in env"
  echo "  dt-bootstrap      Fix DT login 405 + create API key via CLI (no UI)"
  echo "  frontend-heal     Restore UI :30100 (pins master for recovery image)"
  echo "  frontend-force    RS cleanup + pin recovery image when rollout hangs"
  echo "  frontend-stop     Scale frontend to 0 + pause (stop eviction storm)"
  echo "  frontend-safety   Recreate + master pin (prevent pod storms)"
  echo "  emergency       Kyverno webhook unblock + disk + restore PaaS UI"
  echo "  break-loop      STOP cron + pause frontend + break db-repair loop"
  echo "  worker2         Heal worker2 NotReady (Postgres PVC node)"
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
  fix-paas-deploy|cps-split|fix-method-too-large|break-paas-deploy-loop)
    bash "$LIB/fix-paas-deploy-stages-load.sh" ;;
  force-fix-paas-deploy|force-fix)
    bash "$LIB/force-fix-paas-deploy-now.sh" ;;
  jenkins-tools|agent-tools)
    bash "$LIB/lab-jenkins-agent-tools.sh" ;;
  sonarqube|sonar-heal|sonar-recover)
    bash "$LIB/lab-sonarqube-recover.sh" ;;
  sonar-bootstrap|bootstrap-sonar)
    bash "$LIB/bootstrap-sonarqube-lab.sh" ;;
  jenkins-recover|recover-jenkins)
    bash "$LIB/lab-jenkins-recover.sh" recover ;;
  dependency-track|dtrack)
    bash "$LIB/lab-dependency-track.sh" ;;
  dt-bootstrap|dependency-track-bootstrap)
    bash "$LIB/bootstrap-dependency-track-lab.sh" ;;
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

