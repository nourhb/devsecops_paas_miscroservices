#!/usr/bin/env bash
# Install or repair Kyverno; apply ClusterPolicies (webhook optional for PaaS Security UI).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NS="${KYVERNO_NS:-kyverno}"
RELEASE="${KYVERNO_RELEASE:-kyverno}"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
KYVERNO_DIR="${REPO_ROOT}/paas/k8s-manifests/kyverno"
WEBHOOK_WAIT_ROUNDS="${KYVERNO_WEBHOOK_WAIT_ROUNDS:-24}"

kyverno_admission_has_endpoints() {
  local eps svc
  for svc in kyverno-svc "${RELEASE}-svc" kyverno-admission-controller; do
    eps="$(kubectl get endpoints "${svc}" -n "${NS}" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)"
    if [[ -n "${eps}" ]]; then
      return 0
    fi
  done
  # Any endpoints object in kyverno ns with ready addresses
  eps="$(kubectl get endpoints -n "${NS}" -o jsonpath='{range .items[*]}{.subsets[*].addresses[*].ip}{" "}{end}' 2>/dev/null | tr ' ' '\n' | grep -c . || true)"
  [[ "${eps:-0}" -gt 0 ]]
}

kyverno_admission_pods_ready() {
  local ready desired
  ready="$(kubectl get pods -n "${NS}" -l app.kubernetes.io/component=admission-controller \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null \
    | grep -c True || true)"
  desired="$(kubectl get deployment -n "${NS}" -l app.kubernetes.io/component=admission-controller \
    -o jsonpath='{.items[0].spec.replicas}' 2>/dev/null || echo 0)"
  [[ "${ready:-0}" -ge 1 && "${desired:-0}" -ge 1 ]]
}

wait_kyverno_webhook() {
  local i
  for i in $(seq 1 "${WEBHOOK_WAIT_ROUNDS}"); do
    if kyverno_admission_has_endpoints || kyverno_admission_pods_ready; then
      return 0
    fi
    echo "  waiting Kyverno admission webhook (${i}/${WEBHOOK_WAIT_ROUNDS})…"
    sleep 5
  done
  return 1
}

install_kyverno() {
  command -v helm >/dev/null 2>&1 || {
    echo "ERROR: helm required to install Kyverno" >&2
    return 1
  }
  echo "==> Helm install Kyverno (${RELEASE} in ${NS})"
  helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
  helm repo update kyverno >/dev/null 2>&1 || true
  helm upgrade --install "${RELEASE}" kyverno/kyverno -n "${NS}" --create-namespace \
    --set admissionController.replicas=1 \
    --set backgroundController.replicas=1 \
    --set cleanupController.replicas=1 \
    --set reportsController.replicas=1 \
    --timeout 10m
}

repair_kyverno_pods() {
  echo "==> Restart Kyverno controllers"
  kubectl rollout restart deployment -n "${NS}" -l app.kubernetes.io/part-of=kyverno 2>/dev/null \
    || kubectl rollout restart deployment -n "${NS}" 2>/dev/null \
    || true
  kubectl rollout status deployment -n "${NS}" -l app.kubernetes.io/component=admission-controller --timeout=300s 2>/dev/null \
    || kubectl rollout status deployment/kyverno-admission-controller -n "${NS}" --timeout=300s 2>/dev/null \
    || true
}

apply_policies() {
  [[ -f "${KYVERNO_DIR}/require-non-root.yaml" ]] || {
    echo "ERROR: missing ${KYVERNO_DIR}/require-non-root.yaml" >&2
    return 1
  }
  kubectl apply -f "${KYVERNO_DIR}/require-non-root.yaml"
  if [[ -f "${KEYDIR}/cosign.pub" ]]; then
    python3 "${SCRIPT_DIR}/render-kyverno-signed-images-lab.py" \
      "${KEYDIR}/cosign.pub" \
      "${KYVERNO_DIR}/require-signed-images.yaml" \
      "${KYVERNO_DIR}/.require-signed-images.lab.yaml"
    kubectl apply -f "${KYVERNO_DIR}/.require-signed-images.lab.yaml"
  else
    echo "WARN: ${KEYDIR}/cosign.pub missing — skip require-signed-images (run sync-cosign-keys-lab.sh)"
  fi
  echo "OK: Kyverno policies require-non-root + require-signed-images applied"
}

if ! kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  install_kyverno
fi

if ! kubectl get ns "${NS}" >/dev/null 2>&1; then
  install_kyverno
fi

if ! wait_kyverno_webhook; then
  repair_kyverno_pods
  if ! wait_kyverno_webhook; then
    echo "WARN: Kyverno admission webhook still unhealthy (kyverno-svc no endpoints)." >&2
    kubectl get pods,svc,endpoints -n "${NS}" -o wide 2>/dev/null || true
    echo "  PaaS Security UI only needs ClusterPolicy CRs — applying policies anyway." >&2
    echo "  Repair webhook later: bash paas/scripts/recover-kyverno-lab.sh" >&2
  fi
fi

apply_policies
