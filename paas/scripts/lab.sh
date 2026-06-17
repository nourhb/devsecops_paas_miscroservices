#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${DIR}/lib"
cmd="${1:-}"
usage() {
  echo "usage: lab.sh <command>"
  echo "  start     Recover PaaS after reboot"
  echo "  bootstrap Harbor/Kyverno cosign bootstrap"
  echo "  harbor    Recover Harbor registry (502 / crane failures)"
  echo "  db-repair Fix frontend -> Postgres TCP connectivity"
  echo "  health    Quick health check"
  echo "  prometheus  Restart/wait for Prometheus endpoints in monitoring"
  echo "  probe-prometheus  Diagnose Prometheus connectivity from frontend pod"
  echo "  monitoring-disk  Safe disk cleanup (no docker prune -af) + stale pods"
  echo "                   Use: monitoring-disk quick — skip slow cluster-wide image pulls"
  echo "  guard         Full lab hardening check (disk, images, Prometheus, health)"
  echo "  guard-cron    Show/install auto-heal cron (watchdog 10m + guard 6h)"
  echo "  watchdog      Lightweight auto-heal (disk, kyverno, postgres, storms)"
  echo "  harden        One-shot: unpin frontend, db-repair, cron, health"
  echo "  env       Sync docker-compose.env to the frontend pod"
  echo "  jenkins   Sync Jenkinsfile + rebuild PaaS frontend image"
  echo "  dependency-track  Heal DT API server + sync NodePort URL in env"
  echo "  dt-bootstrap      Fix DT login 405 + create API key via CLI (no UI)"
  echo "  frontend-heal     Unpin frontend nodeSelector + restore UI :30100"
  echo "  emergency       Kyverno webhook unblock + disk + restore PaaS UI"
  echo "  break-loop      STOP cron + pause frontend + break db-repair loop"
  echo "  worker2         Heal worker2 NotReady (Postgres PVC node)"
  echo "  frontend  Rebuild and roll out PaaS frontend image only"
  echo "  repair    Rebuild GitOps Helm chart (fix invalid K8s names)"
  echo "  fix-gitops  Abort rebase and reset ~/gitops to origin/main"
  echo "  heal      Patch GitOps values + Argo sync + rollout"
  echo "  deploy    git pull + Kyverno Audit + cosign try + heal (one-shot)"
  echo "  ultimate  Full fix: Kyverno HTTP Harbor + GitOps + deploy (one command)"
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
  health|check)
    bash "$LIB/check-paas-lab-health.sh" ;;
  prometheus|prom)
    bash "$LIB/lab-prometheus-recover.sh" ;;
  probe-prometheus)
    bash "$LIB/probe-prometheus-lab.sh" ;;
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
  env)
    bash "$LIB/sync-cosign-public-key-env.sh" || true
    bash "$LIB/compose-paas-frontend-env.sh"
    LAB_DT_ENV_ONLY=true bash "$LIB/lab-dependency-track.sh" || true
    bash "$LIB/sync-paas-frontend-env-k8s.sh" ;;
  jenkins)
    bash "$LIB/sync-jenkins-pipeline-from-repo.sh" ;;
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
  emergency|unblock)
    bash "$LIB/lab-emergency-unblock.sh" ;;
  break-loop|stop-loop|break)
    bash "$LIB/lab-break-loop.sh" ;;
  worker2|worker2-heal)
    bash "$LIB/lab-worker2-heal.sh" ;;
  frontend)
    bash "$LIB/rebuild-paas-frontend-lab.sh" ;;
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
