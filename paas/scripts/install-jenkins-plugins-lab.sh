#!/usr/bin/env bash
# Install Pipeline plugins on lab Jenkins (required before createItem / paas-deploy).
# Run on master: bash paas/scripts/install-jenkins-plugins-lab.sh
set -euo pipefail

REPO="${REPO:-$HOME/devsecops_paas_miscroservices}"
NS="${JENKINS_NS:-cicd}"
ENV_FILE="${ENV_FILE:-$REPO/paas/frontend/docker-compose.env}"
JENKINS_URL="${JENKINS_BASE_URL:-http://127.0.0.1:30090}"

kubectl create namespace "$NS" 2>/dev/null || true
kubectl apply -f "$REPO/paas/k8s-manifests/lab/jenkins-plugins-configmap.yaml"

echo "==> Wait for Jenkins pod"
kubectl wait --for=condition=ready pod -l app=jenkins -n "$NS" --timeout=300s
POD="$(kubectl get pod -n "$NS" -l app=jenkins -o jsonpath='{.items[0].metadata.name}')"
echo "Pod: $POD"

if kubectl exec -n "$NS" "$POD" -- test -f /var/jenkins_home/plugins/workflow-job.jpi 2>/dev/null; then
  echo "workflow-job already installed"
  exit 0
fi

echo "==> Install plugins via jenkins-plugin-cli (may take 3–8 min on slow lab network)"
kubectl exec -n "$NS" "$POD" -u root -- bash -c '
set -euo pipefail
cp /var/jenkins_ref_plugins/plugins.txt /tmp/plugins.txt
CLI=""
for c in jenkins-plugin-cli /usr/bin/jenkins-plugin-cli /usr/local/bin/jenkins-plugin-cli; do
  if command -v "$c" >/dev/null 2>&1; then CLI="$c"; break; fi
done
if [ -z "$CLI" ] && [ -x /usr/local/bin/install-plugins.sh ]; then
  /usr/local/bin/install-plugins.sh < /tmp/plugins.txt
  chown -R jenkins:jenkins /var/jenkins_home/plugins 2>/dev/null || true
  exit 0
fi
if [ -z "$CLI" ]; then
  echo "ERROR: no jenkins-plugin-cli or install-plugins.sh in image" >&2
  exit 1
fi
$CLI --plugin-file /tmp/plugins.txt --verbose
chown -R jenkins:jenkins /var/jenkins_home/plugins 2>/dev/null || true
'

echo "==> Restart Jenkins to load plugins"
kubectl rollout restart deployment/jenkins -n "$NS"
kubectl rollout status deployment/jenkins -n "$NS" --timeout=600s
kubectl wait --for=condition=ready pod -l app=jenkins -n "$NS" --timeout=300s

# shellcheck disable=SC1090
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a
USER="${JENKINS_USERNAME:-admin}"
TOKEN="${JENKINS_API_TOKEN:-}"

echo "==> Wait for workflow-job active (API)"
for i in $(seq 1 120); do
  POD="$(kubectl get pod -n "$NS" -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "$TOKEN" ]]; then
    body="$(curl -s -m 10 -u "${USER}:${TOKEN}" "${JENKINS_URL%/}/pluginManager/api/json?depth=1" || true)"
    if echo "$body" | grep -q '"shortName":"workflow-job"' && echo "$body" | grep -q '"active":true'; then
      echo "Pipeline plugins ready"
      exit 0
    fi
  fi
  if [[ -n "$POD" ]] && kubectl exec -n "$NS" "$POD" -- test -f /var/jenkins_home/plugins/workflow-job.jpi 2>/dev/null; then
    echo "workflow-job.jpi on disk (waiting API active $i/120)..."
  else
    echo "waiting plugins ($i/120)..."
  fi
  sleep 5
done

echo "WARN: workflow-job not confirmed active — try create job anyway or check Jenkins → Plugins" >&2
exit 1
