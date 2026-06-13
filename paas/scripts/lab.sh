#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"
usage() {
  echo "usage: lab.sh <command>"
  echo "  start     Recover PaaS after reboot"
  echo "  health    Quick health check"
  echo "  env       Sync docker-compose.env to the frontend pod"
  echo "  jenkins   Sync Jenkinsfile to the paas-deploy job"
}
case "$cmd" in
  start|recover)
    bash "$DIR/recover-paas-after-k3s-restart.sh" ;;
  health|check)
    bash "$DIR/check-paas-lab-health.sh" ;;
  env)
    bash "$DIR/sync-paas-frontend-env-k8s.sh" ;;
  jenkins)
    bash "$DIR/sync-jenkins-pipeline-from-repo.sh" ;;
  ""|-h|--help|help)
    usage
    exit 0 ;;
  *)
    echo "unknown: $cmd" >&2
    usage
    exit 1 ;;
esac
