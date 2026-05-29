#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"
shift || true

case "$cmd" in
  start|recover)
    bash "$DIR/recover-paas-after-k3s-restart.sh" ;;
  health|check)
    bash "$DIR/check-paas-lab-health.sh" ;;
  bootstrap)
    bash "$DIR/bootstrap-paas-lab.sh" ;;
  deploy)
    bash "$DIR/final-deploy-simple-app-lab.sh" "$@" ;;
  app)
    bash "$DIR/fix-simple-app-lab.sh" "$@" ;;
  jenkins)
    bash "$DIR/fix-jenkins-paas-deploy-pipeline-lab.sh" ;;
  env)
    bash "$DIR/sync-paas-frontend-env-k8s.sh" ;;
  seed)
    bash "$DIR/seed-admin-user-lab.sh" "$@" ;;
  autostart)
    bash "$DIR/install-paas-autostart-lab.sh" ;;
  postgres)
    bash "$DIR/fix-postgres-pvc-schedule-lab.sh" ;;
  integrations)
    bash "$DIR/fix-integrations-lab.sh" ;;
  integrations-wire)
    bash "$DIR/wire-optional-integrations-lab.sh"
    ENV_FILE="${ENV_FILE:-$DIR/../frontend/docker-compose.env}" bash "$DIR/sync-paas-frontend-env-k8s.sh" ;;
  integrations-diagnose|diag-integrations)
    bash "$DIR/diagnose-integration-pods-lab.sh" ;;
  integrations-start)
    bash "$DIR/start-lab-integration-workloads.sh" ;;
  security|sec)
    if [[ -f "$DIR/setup-security-lab.sh" ]]; then
      bash "$DIR/setup-security-lab.sh"
    else
      echo "ERROR: missing $DIR/setup-security-lab.sh — git pull or copy from repo (paas/scripts/setup-security-lab.sh)" >&2
      exit 1
    fi ;;
  jenkins-recover|recover-jenkins)
    bash "$DIR/recover-jenkins-stuck-lab.sh" ;;
  fix-deployments|deployments-reset)
    bash "$DIR/fix-stuck-paas-deployments-lab.sh" ;;
  jenkins-status|jenkins-queue)
    bash "$DIR/jenkins-status-lab.sh" ;;
  jenkins-executors|fix-executors)
    bash "$DIR/fix-jenkins-executor-queue-lab.sh" ;;
  jenkins-abort|abort-zombies)
    bash "$DIR/abort-jenkins-zombie-builds-lab.sh" ;;
  fix-all|recover-all)
    bash "$DIR/fix-all-paas-lab.sh" ;;
  ultra|ultra-fix|pipeline-fix)
    bash "$DIR/ultra-fix-paas-pipeline-lab.sh" ;;
  unblock|jenkins-unblock)
    bash "$DIR/jenkins-unblock-lab.sh" ;;
  "")
    echo "usage: lab.sh unblock|ultra|fix-all|jenkins-status|..."
    exit 1 ;;
  *)
    echo "unknown: $cmd"
    exit 1 ;;
esac
