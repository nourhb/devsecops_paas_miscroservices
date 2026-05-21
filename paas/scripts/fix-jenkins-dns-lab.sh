#!/usr/bin/env bash
# Fix "Could not resolve host: github.com" from Jenkins (and other pods) on k3s lab.
# Run on master: bash paas/scripts/fix-jenkins-dns-lab.sh
set -euo pipefail

NS="${JENKINS_NS:-cicd}"
DEPLOY="${JENKINS_DEPLOY:-jenkins}"

echo "=== 1. DNS from host ==="
getent hosts github.com || nslookup github.com || true
curl -sI -m 10 https://github.com | head -3 || echo "WARN: host cannot reach github.com"

echo ""
echo "=== 2. DNS from Jenkins pod (before fix) ==="
kubectl exec -n "$NS" "deploy/${DEPLOY}" -- getent hosts github.com 2>&1 || true

echo ""
echo "=== 3. CoreDNS / kube-dns ==="
kubectl get pods -n kube-system 2>/dev/null | grep -iE 'coredns|dns' || true
kubectl get svc -n kube-system kube-dns 2>/dev/null || kubectl get svc -n kube-system -l k8s-app=kube-dns 2>/dev/null || true

echo ""
echo "=== 4. Patch Jenkins to use public DNS (8.8.8.8 / 1.1.1.1) if cluster DNS is broken ==="
kubectl patch deployment "$DEPLOY" -n "$NS" --type=strategic -p '{
  "spec": {
    "template": {
      "spec": {
        "dnsPolicy": "None",
        "dnsConfig": {
          "nameservers": ["8.8.8.8", "1.1.1.1"],
          "searches": ["cicd.svc.cluster.local", "svc.cluster.local", "cluster.local"],
          "options": [{ "name": "ndots", "value": "5" }]
        }
      }
    }
  }
}' 2>/dev/null || echo "WARN: patch failed — apply jenkins manifest manually"

kubectl rollout status "deployment/${DEPLOY}" -n "$NS" --timeout=300s
kubectl wait --for=condition=ready pod -l app=jenkins -n "$NS" --timeout=120s

echo ""
echo "=== 5. DNS from Jenkins pod (after fix) ==="
kubectl exec -n "$NS" "deploy/${DEPLOY}" -- getent hosts github.com
kubectl exec -n "$NS" "deploy/${DEPLOY}" -- curl -sI -m 15 https://github.com | head -3

echo ""
echo "OK — re-run paas-deploy build from PaaS or Jenkins UI"
