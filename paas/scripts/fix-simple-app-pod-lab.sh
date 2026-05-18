#!/usr/bin/env bash
# Fix simple-app pod: runAsNonRoot + Harbor registry + disk on workers.
set -euo pipefail

GITOPS="${GITOPS:-${HOME}/gitops}"
DEP="${GITOPS}/apps/simple-app/templates/deployment.yaml"
NS=simple-app

echo "=== 1. Patch deployment (allow root user for crane image) ==="
if [[ -f "$DEP" ]]; then
  sed -i 's/readOnlyRootFilesystem: true/readOnlyRootFilesystem: false/g' "$DEP"
  sed -i 's/runAsNonRoot: true/runAsNonRoot: false/g' "$DEP"
  grep -q 'containerPort: 3000' "$DEP" || sed -i '/imagePullPolicy: IfNotPresent/a\          ports:\n            - name: http\n              containerPort: 3000\n              protocol: TCP' "$DEP"
  echo "Patched $DEP"
else
  echo "WARN: $DEP not found — clone gitops first"
fi

if [[ -n "${GITHUB_TOKEN:-}" ]] && [[ -d "${GITOPS}/.git" ]]; then
  cd "$GITOPS"
  git add apps/simple-app/templates/deployment.yaml
  if ! git diff --cached --quiet; then
    git commit -m "fix(simple-app): allow root user for Jenkins crane image"
    git push "https://${GITHUB_TOKEN}@github.com/nourhb/gitops.git" main
  fi
fi

echo "=== 2. Harbor registry (must be Running to pull :100) ==="
kubectl rollout restart deployment -n harbor harbor-registry harbor-nginx 2>/dev/null || true
kubectl wait --for=condition=ready pod -l app=harbor,component=registry -n harbor --timeout=300s 2>/dev/null || {
  echo "WARN: harbor-registry not ready — check:"
  kubectl describe pod -n harbor -l app=harbor,component=registry | tail -25
}

echo "=== 3. Clean failed simple-app pods ==="
kubectl delete pod -n "$NS" -l app.kubernetes.io/name=simple-app --force --grace-period=0 2>/dev/null || true

if command -v argocd >/dev/null; then
  argocd app sync paas-simple-app --force || true
fi

echo "=== 4. Status ==="
sleep 12
kubectl get pods -n "$NS"
kubectl get pods -n harbor -l app=harbor,component=registry
curl -sS -o /dev/null -w 'Harbor %{http_code}\n' http://192.168.56.129:30002/api/v2.0/ping || true
curl -sS -o /dev/null -w 'App HTTP %{http_code}\n' http://simple-app.192.168.56.129.nip.io:30659/ || true
