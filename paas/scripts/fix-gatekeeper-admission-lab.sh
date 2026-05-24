#!/usr/bin/env bash
set -euo pipefail

IGNORE_WEBHOOKS=false
DELETE_WEBHOOKS=false
for arg in "$@"; do
  case "$arg" in
    --ignore-webhooks) IGNORE_WEBHOOKS=true ;;
    --delete-webhooks) DELETE_WEBHOOKS=true ;;
  esac
done

echo "=== Gatekeeper pods (gatekeeper-system) ==="
kubectl get pods -n gatekeeper-system -o wide 2>/dev/null || echo "(namespace gatekeeper-system missing)"

echo ""
echo "=== Webhook service endpoints ==="
kubectl get endpoints -n gatekeeper-system 2>/dev/null || true

echo ""
echo "=== Restart Gatekeeper controllers (if present) ==="
if kubectl get ns gatekeeper-system >/dev/null 2>&1; then
  for d in $(kubectl get deploy -n gatekeeper-system -o name 2>/dev/null); do
    echo "rollout restart $d"
    kubectl rollout restart -n gatekeeper-system "${d#deployment.apps/}" 2>/dev/null || kubectl rollout restart -n gatekeeper-system "$d" || true
  done
  for d in $(kubectl get deploy -n gatekeeper-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    kubectl rollout status -n gatekeeper-system "deployment/$d" --timeout=180s || true
  done
fi

echo ""
echo "=== Endpoints after restart ==="
kubectl get endpoints -n gatekeeper-system 2>/dev/null || true

READY=$(kubectl get endpoints gatekeeper-webhook-service -n gatekeeper-system -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)
if [[ -n "$READY" ]]; then
  echo "OK: gatekeeper-webhook-service has endpoints. Retry: argocd app sync paas-simple-app"
  exit 0
fi

echo ""
echo "WARN: gatekeeper-webhook-service still has no endpoints."
echo ""
echo "=== Deployments / events (why no pods?) ==="
kubectl get deploy,rs -n gatekeeper-system 2>/dev/null || true
kubectl get events -n gatekeeper-system --sort-by='.lastTimestamp' 2>/dev/null | tail -15 || true

echo ""
echo "=== Gatekeeper admission webhooks (name + failurePolicy) ==="
for cfg in $(kubectl get validatingwebhookconfiguration -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i gatekeeper || true); do
  kubectl get validatingwebhookconfiguration "$cfg" -o jsonpath='{range .webhooks[*]}{.name}{"  failurePolicy="}{.failurePolicy}{"\n"}{end}' 2>/dev/null | sed "s/^/  $cfg /"
done

if [[ "$DELETE_WEBHOOKS" == "true" ]]; then
  echo ""
  echo "=== LAB: delete Gatekeeper webhook configurations ==="
  kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep -i gatekeeper | xargs -r kubectl delete || true
  kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i gatekeeper | xargs -r kubectl delete || true
  echo "Done. Retry: argocd app sync paas-simple-app"
  exit 0
fi

if [[ "$IGNORE_WEBHOOKS" != "true" ]]; then
  echo ""
  echo "Next (lab):"
  echo "  bash paas/scripts/fix-gatekeeper-admission-lab.sh --ignore-webhooks   # all webhooks → Ignore"
  echo "  bash paas/scripts/fix-gatekeeper-admission-lab.sh --delete-webhooks   # remove Gatekeeper admission"
  exit 1
fi

patch_all_webhooks_ignore() {
  local kind="$1"
  for cfg in $(kubectl get "$kind" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -i gatekeeper || true); do
    echo "Patching $kind/$cfg (every webhook entry)"
    if command -v jq >/dev/null 2>&1; then
      kubectl get "$kind" "$cfg" -o json | jq '.webhooks |= map(.failurePolicy = "Ignore")' | kubectl apply -f -
    else
      n=$(kubectl get "$kind" "$cfg" -o jsonpath='{len(.webhooks)}')
      i=0
      while [ "$i" -lt "$n" ]; do
        kubectl patch "$kind" "$cfg" --type=json -p="[{\"op\":\"replace\",\"path\":\"/webhooks/$i/failurePolicy\",\"value\":\"Ignore\"}]" || true
        i=$((i + 1))
      done
    fi
  done
}

echo ""
echo "=== LAB: set failurePolicy=Ignore on ALL Gatekeeper webhook entries ==="
patch_all_webhooks_ignore validatingwebhookconfiguration
patch_all_webhooks_ignore mutatingwebhookconfiguration

echo ""
echo "Test namespace create:"
if kubectl create namespace simple-app-gk-test --dry-run=server -o name 2>/dev/null; then
  kubectl delete namespace simple-app-gk-test --ignore-not-found 2>/dev/null || true
  echo "Admission OK."
else
  echo "Still blocked — try: bash paas/scripts/fix-gatekeeper-admission-lab.sh --delete-webhooks"
fi

echo ""
echo "Retry: argocd app sync paas-simple-app"
