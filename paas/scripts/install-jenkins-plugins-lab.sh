#!/usr/bin/env bash
# Install Pipeline plugins on lab Jenkins (required before createItem / paas-deploy).
# Run on master: bash paas/scripts/install-jenkins-plugins-lab.sh
set -euo pipefail

REPO="${REPO:-$HOME/devsecops_paas_miscroservices}"
NS="${JENKINS_NS:-cicd}"
ENV_FILE="${ENV_FILE:-$REPO/paas/frontend/docker-compose.env}"
# Host scripts must not use in-cluster JENKINS_BASE_URL from docker-compose.env (DNS fails on VM).
JENKINS_URL="${JENKINS_LAB_LOOPBACK:-http://127.0.0.1:30090}"
if [[ -f "$ENV_FILE" ]]; then
  _b="$(grep -E '^JENKINS_BASE_URL=' "$ENV_FILE" | cut -d= -f2- | tr -d '\r' || true)"
  if [[ -n "$_b" && "$_b" != *".svc.cluster.local"* ]]; then
    JENKINS_URL="${_b%/}"
  fi
fi

kubectl create namespace "$NS" 2>/dev/null || true
if [[ -f "$REPO/paas/k8s-manifests/lab/jenkins-plugins-configmap.yaml" ]]; then
  kubectl apply -f "$REPO/paas/k8s-manifests/lab/jenkins-plugins-configmap.yaml"
fi

echo "==> Wait for Jenkins pod"
kubectl wait --for=condition=ready pod -l app=jenkins -n "$NS" --timeout=300s
POD="$(kubectl get pod -n "$NS" -l app=jenkins -o jsonpath='{.items[0].metadata.name}')"
echo "Pod: $POD"

echo "==> Diagnose plugin dirs"
kubectl exec -n "$NS" "$POD" -- bash -c '
echo -n "ref .jpi count: "; ls /usr/share/jenkins/ref/plugins/*.jpi 2>/dev/null | wc -l
echo -n "home .jpi count: "; ls /var/jenkins_home/plugins/*.jpi 2>/dev/null | wc -l
echo -n "home workflow dirs: "; ls -d /var/jenkins_home/plugins/workflow-* 2>/dev/null | wc -l
' || true

if kubectl exec -n "$NS" "$POD" -- bash -c 'test -d /var/jenkins_home/plugins/workflow-job || test -f /var/jenkins_home/plugins/workflow-job.jpi' 2>/dev/null; then
  echo "workflow-job already installed in JENKINS_HOME"
  exit 0
fi
# Plugins may have been downloaded to ref/ only (PVC already existed).
if kubectl exec -n "$NS" "$POD" -- bash -c 'ls /usr/share/jenkins/ref/plugins/workflow-job*.jpi 2>/dev/null | head -1' 2>/dev/null | grep -q .; then
  echo "==> Copy plugins from ref/ into /var/jenkins_home/plugins/"
  kubectl exec -n "$NS" "$POD" -- bash -c 'mkdir -p /var/jenkins_home/plugins && cp -f /usr/share/jenkins/ref/plugins/*.jpi /var/jenkins_home/plugins/ 2>/dev/null || true'
  if kubectl exec -n "$NS" "$POD" -- bash -c 'test -d /var/jenkins_home/plugins/workflow-job || ls /var/jenkins_home/plugins/workflow-job*.jpi 2>/dev/null' 2>/dev/null | grep -q .; then
    echo "workflow-job copied to JENKINS_HOME — restart Jenkins"
    kubectl rollout restart deployment/jenkins -n "$NS"
    kubectl rollout status deployment/jenkins -n "$NS" --timeout=600s
    kubectl wait --for=condition=ready pod -l app=jenkins -n "$NS" --timeout=300s
    exit 0
  fi
fi

echo "==> Install plugins via jenkins-plugin-cli (may take 3–8 min on slow lab network)"
# Older kubectl (e.g. k3s bundled) has no "kubectl exec -u"; run as container default user (jenkins).
kubectl exec -n "$NS" "$POD" -- bash -c '
set -euo pipefail
if [ -f /var/jenkins_ref_plugins/plugins.txt ]; then
  cp /var/jenkins_ref_plugins/plugins.txt /tmp/plugins.txt
else
  cat > /tmp/plugins.txt <<PLUG
workflow-aggregator
git
credentials-binding
plain-credentials
ssh-credentials
PLUG
fi
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
export JENKINS_HOME=/var/jenkins_home
mkdir -p "$JENKINS_HOME/plugins"
$CLI --plugin-file /tmp/plugins.txt --plugin-download-directory "$JENKINS_HOME/plugins" --verbose
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
    if echo "$body" | grep -Eq '"shortName":"(workflow-job|workflow-cps|workflow-aggregator)"'; then
      echo "Pipeline plugins ready (API)"
      exit 0
    fi
  fi
  if [[ -n "$POD" ]] && kubectl exec -n "$NS" "$POD" -- bash -c 'test -d /var/jenkins_home/plugins/workflow-job || ls /var/jenkins_home/plugins/workflow-job*.jpi 2>/dev/null' 2>/dev/null | grep -q .; then
    echo "workflow-job.jpi on disk (waiting API active $i/120)..."
  else
    echo "waiting plugins ($i/120)..."
  fi
  sleep 5
done

echo "WARN: workflow-job not confirmed active — try create job anyway or check Jenkins → Plugins" >&2
exit 1
