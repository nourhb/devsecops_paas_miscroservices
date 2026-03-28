#!/usr/bin/env bash
set -euo pipefail

BASE_URL=${BASE_URL:-http://localhost:4000}

echo "1) Verify integration endpoints from backend"
curl -sS ${BASE_URL}/api/integrations/status | jq . || true

echo "\n2) Run backend smoke tests"
node paas/backend-next/scripts/smoke-test.js || true

echo "\n3) Instructions for infra tests (manual):"
echo " - Drain a worker: kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data"
echo " - Watch Prometheus/Grafana dashboards for node down metrics"
echo " - Uncordon: kubectl uncordon worker1"

echo "\n4) CI/CD tests (manual): push branch-B to your SCM to trigger Jenkins pipeline; pipeline should fail on Sonar/Trivy failures"

echo "\n5) GitOps test (manual): modify Helm values in gitops repo and commit; ArgoCD should auto-sync"

echo "\n6) Runtime security test (manual): attempt to apply a Pod manifest using an unsigned image; OPA Gatekeeper should deny it"

echo "E2E helper script finished. See paas/test-app for test artifacts and Jenkinsfile.template for pipeline steps."
