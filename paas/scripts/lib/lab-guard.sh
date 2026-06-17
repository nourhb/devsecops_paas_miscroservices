#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
NODE_IP="${NODE_IP:-192.168.56.129}"
MON_NS="${PROMETHEUS_K8S_NAMESPACE:-monitoring}"
PAAS_NS="${PAAS_NS:-paas}"
FAIL=0

warn() { echo "WARN: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
ok() { echo "OK: $*"; }

echo "=============================================="
echo " lab-guard — prevent disk / image / monitoring regressions"
echo "=============================================="

echo "==> Kyverno webhook fail-open"
bash "${SCRIPT_DIR}/lab-kyverno-webhook-guard.sh" guard || warn "kyverno webhook guard failed"

echo "==> Frontend schedule (no master pin / Never pull)"
if kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
  NS_JSON="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.nodeSelector}' 2>/dev/null || true)"
  if [[ -n "${NS_JSON}" && "${NS_JSON}" != "{}" ]]; then
    warn "frontend nodeSelector present — unpinning"
    kubectl patch deployment frontend -n "${PAAS_NS}" --type=json \
      -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' 2>/dev/null \
      || kubectl patch deployment frontend -n "${PAAS_NS}" --type=strategic \
        -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}' || true
  else
    ok "no frontend nodeSelector"
  fi
  FPOL="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || true)"
  if [[ "${FPOL}" == "Never" ]]; then
    warn "frontend imagePullPolicy=Never — switching to IfNotPresent"
    kubectl patch deployment frontend -n "${PAAS_NS}" --type=json \
      -p='[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' 2>/dev/null || true
  fi
fi

echo "==> Disk usage"
df -h / /var/lib/rancher 2>/dev/null | tail -n +2 || df -h /
DISK_PCT="$(df / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5}')"
if [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 85 ]]; then
  warn "root disk at ${DISK_PCT}% — run safe cleanup (no docker prune -af)"
  bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true
  PROMETHEUS_RECOVER_SKIP_GRAFANA=1 bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" prune || true
elif [[ -n "${DISK_PCT}" && "${DISK_PCT}" -ge 80 ]]; then
  warn "root disk at ${DISK_PCT}% — pruning only dangling docker layers"
  bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" prune || true
else
  ok "disk ${DISK_PCT:-?}%"
fi

if kubectl describe node master 2>/dev/null | grep -q 'DiskPressure.*True'; then
  warn "master DiskPressure=True — cleaning stale pods"
  bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true
fi

echo "==> Workload images referenced by deployments"
if ! bash "${SCRIPT_DIR}/lab-safe-image-prune.sh" ensure; then
  warn "one or more deployment images missing — rebuilding PaaS frontend"
  bash "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh" || fail "frontend rebuild failed"
fi

FRONTEND_IMAGE="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ -n "${FRONTEND_IMAGE}" ]]; then
  FP="$(kubectl get pods -n "${PAAS_NS}" -l app=frontend -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)"
  if [[ "${FP}" == ImagePullBackOff || "${FP}" == ErrImageNeverPull ]]; then
    warn "frontend ${FP} for ${FRONTEND_IMAGE}"
    bash "${SCRIPT_DIR}/rebuild-paas-frontend-lab.sh" || fail "frontend rebuild failed"
  else
    ok "frontend image ${FRONTEND_IMAGE}"
  fi
fi

echo "==> Prometheus endpoints"
PROM_EP="$(kubectl get endpoints -n "${MON_NS}" kube-prometheus-stack-prometheus -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
if [[ -z "${PROM_EP}" ]]; then
  warn "no prometheus endpoints — running recover"
  PROMETHEUS_RECOVER_SKIP_GRAFANA=1 bash "${SCRIPT_DIR}/lab-prometheus-recover.sh" || fail "prometheus recover failed"
else
  ok "prometheus endpoint ${PROM_EP}"
fi

echo "==> Kyverno monitoring exclude"
if ! kubectl get clusterpolicy require-non-root -o yaml 2>/dev/null | grep -qE '^[[:space:]]*-[[:space:]]*monitoring[[:space:]]*$'; then
  warn "require-non-root missing monitoring exclude — applying policies"
  bash "${SCRIPT_DIR}/lab-kyverno.sh" apply || fail "kyverno apply failed"
else
  ok "kyverno excludes monitoring"
fi

echo "==> Stale pods (cluster-wide)"
bash "${SCRIPT_DIR}/lab-stale-pod-cleanup.sh" || true

echo "==> Prometheus probe"
if bash "${SCRIPT_DIR}/probe-prometheus-lab.sh"; then
  ok "prometheus probe"
else
  fail "prometheus probe failed"
fi

echo "==> PaaS health"
if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
  ok "paas health"
else
  warn "paas health failed — attempting db-repair"
  bash "${SCRIPT_DIR}/lab-paas-db-repair.sh" || true
  if bash "${SCRIPT_DIR}/check-paas-lab-health.sh"; then
    ok "paas health after db-repair"
  else
    fail "paas health check failed"
  fi
fi

echo "=============================================="
if [[ "${FAIL}" -eq 0 ]]; then
  echo "lab-guard: all checks passed"
  echo "Tip: run after reboot or before demos: bash paas/scripts/lab.sh guard"
  exit 0
fi
echo "lab-guard: some checks failed — review WARN/FAIL above"
exit 1
