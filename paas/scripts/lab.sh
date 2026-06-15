#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
cmd="${1:-}"
usage() {
  echo "usage: lab.sh <command>"
  echo "  start     Recover PaaS after reboot"
  echo "  bootstrap Harbor/Kyverno cosign bootstrap"
  echo "  health    Quick health check"
  echo "  env       Sync docker-compose.env to the frontend pod"
  echo "  jenkins   Sync Jenkinsfile to the paas-deploy job"
  echo "  repair    Rebuild GitOps Helm chart (fix invalid K8s names)"
  echo "  fix-gitops  Abort rebase and reset ~/gitops to origin/main"
  echo "  heal      Patch GitOps values + Argo sync + rollout"
}
case "$cmd" in
  start|recover)
    bash "$DIR/recover-paas-after-k3s-restart.sh" ;;
  bootstrap)
    bash "$DIR/platform-bootstrap-lab.sh" ;;
  health|check)
    bash "$DIR/check-paas-lab-health.sh" ;;
  env)
    bash "$DIR/sync-paas-frontend-env-k8s.sh" ;;
  jenkins)
    bash "$DIR/sync-jenkins-pipeline-from-repo.sh" ;;
  repair)
    bash "$DIR/repair-gitops-app-lab.sh" "${2:?usage: lab.sh repair <project-slug> [tag]}" "${3:-655}" ;;
  fix-gitops)
    bash "$DIR/fix-gitops-repo-lab.sh" ;;
  heal)
    bash "$DIR/heal-project-deploy-lab.sh" "${2:?usage: lab.sh heal <project-slug> <build> [port]}" "${3:?}" "${4:-3000}" ;;
  ""|-h|--help|help)
    usage
    exit 0 ;;
  *)
    echo "unknown: $cmd" >&2
    usage
    exit 1 ;;
esac
