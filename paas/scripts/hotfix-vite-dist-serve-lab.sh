#!/usr/bin/env bash
# Emergency: Vite apps (dist/) crash with "npm error Missing script: start" on :322 images.
# Overrides container command to serve dist/ until a new Jenkins build includes start-paas.sh dist fix.
set -euo pipefail

PROJECT_NAME="${1:?usage: hotfix-vite-dist-serve-lab.sh <projectName>}"
NS="${2:-${PROJECT_NAME}}"
PORT="${APP_PORT:-3000}"

echo "==> Patch deployments in namespace ${NS} to serve /app/dist"
for dep in $(kubectl get deploy -n "${NS}" -o name 2>/dev/null | sed 's|deployment.apps/||'); do
  echo "  ${dep}"
  kubectl patch deployment "${dep}" -n "${NS}" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/command\",\"value\":[\"sh\",\"-c\",\"cd /app && exec npx --yes serve@14 -s dist -l ${PORT}\"]},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[]}
  ]" >/dev/null
done

echo "==> Wait for rollout"
kubectl rollout status deployment -n "${NS}" --timeout=180s || true
kubectl get pods -n "${NS}"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 15 \
  "http://${PROJECT_NAME}.192.168.56.129.nip.io:30659/" 2>/dev/null || echo 000)"
echo "HTTP ${HTTP} — http://${PROJECT_NAME}.192.168.56.129.nip.io:30659/"
echo ""
echo "Permanent fix: rebuild with Jenkinsfile start-paas.sh dist/ branch (build #328+), then promote that tag."
