#!/usr/bin/env bash
# Bypass GitOps: set deployment image + Vite dist serve (when pods stuck on old tag / npm start crash).
set -euo pipefail

PROJECT_NAME="${1:?usage: kubectl-set-paas-image-lab.sh <projectName> <tag>}"
TAG="${2:?usage: kubectl-set-paas-image-lab.sh <projectName> <tag>}"
NS="${3:-${PROJECT_NAME}}"
NODE_IP="${NODE_IP:-192.168.56.129}"
IMAGE="${NODE_IP}:30002/paas/${PROJECT_NAME}:${TAG}"
PORT="${APP_PORT:-3000}"

SERVE_CMD="cd /app && exec npx --yes serve@14 -s dist -l ${PORT}"

echo "==> Set image ${IMAGE} on all deployments in ${NS}"
for dep in $(kubectl get deploy -n "${NS}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  cname="$(kubectl get deploy "${dep}" -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].name}')"
  echo "  ${dep} container=${cname}"
  kubectl set image "deployment/${dep}" -n "${NS}" "${cname}=${IMAGE}"
  kubectl patch deployment "${dep}" -n "${NS}" --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/command\",\"value\":[\"sh\",\"-c\",\"${SERVE_CMD}\"]},
    {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[]}
  ]" >/dev/null
done

kubectl rollout status deployment -n "${NS}" --timeout=300s || true
kubectl get pods -n "${NS}"
HTTP="$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 20 \
  "http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/" 2>/dev/null || echo 000)"
echo "HTTP ${HTTP} http://${PROJECT_NAME}.${NODE_IP}.nip.io:30659/"
