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
  integrations-diagnose|diag-integrations)
    bash "$DIR/diagnose-integration-pods-lab.sh" ;;
  "")
    echo "usage: lab.sh start|health|integrations|integrations-diagnose|..."
    exit 1 ;;
  *)
    echo "unknown: $cmd"
    exit 1 ;;
esac
