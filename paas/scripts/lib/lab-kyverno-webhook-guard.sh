#!/usr/bin/env bash
set -euo pipefail

kyverno_admission_up() {
  kubectl get endpoints -n kyverno kyverno-svc -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -q .
}

kyverno_admission_responds() {
  local err
  err="$(kubectl create configmap kyverno-lab-probe --dry-run=server -n default -o name 2>&1 || true)"
  if echo "${err}" | grep -qiE 'kyverno.*502|kyverno-svc.*fail|failed calling webhook.*kyverno'; then
    return 1
  fi
  return 0
}

kyverno_admission_healthy() {
  kyverno_admission_up && kyverno_admission_responds
}

kyverno_webhooks_present() {
  kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -qi kyverno \
    || kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -qi kyverno
}

remove_kyverno_webhooks() {
  local w removed=0
  for w in $(kubectl get mutatingwebhookconfigurations -o name 2>/dev/null | grep -i kyverno || true); do
    echo "delete ${w}"
    kubectl delete "${w}" --ignore-not-found --wait=false || true
    removed=1
  done
  for w in $(kubectl get validatingwebhookconfigurations -o name 2>/dev/null | grep -i kyverno || true); do
    echo "delete ${w}"
    kubectl delete "${w}" --ignore-not-found --wait=false || true
    removed=1
  done
  [[ "${removed}" -eq 1 ]]
}

restart_kyverno_admission() {
  if ! kubectl get ns kyverno >/dev/null 2>&1; then
    return 0
  fi
  kubectl rollout restart deployment/kyverno-admission-controller -n kyverno 2>/dev/null || true
  kubectl rollout status deployment/kyverno-admission-controller -n kyverno --timeout=180s 2>/dev/null || true
}

case "${1:-guard}" in
  guard)
    if [[ "${PAAS_FORCE_KYVERNO_UNBLOCK:-}" == "1" ]] && kyverno_webhooks_present; then
      echo "WARN: PAAS_FORCE_KYVERNO_UNBLOCK=1 — removing Kyverno webhooks"
      remove_kyverno_webhooks
      echo "OK: kyverno webhooks cleared (lab fail-open)"
      exit 0
    fi
    if kyverno_admission_healthy; then
      echo "OK: kyverno admission healthy"
      exit 0
    fi
    if kyverno_admission_up && ! kyverno_admission_responds; then
      echo "WARN: kyverno has endpoints but mutate webhook returns 502 — removing fail-closed hooks"
      remove_kyverno_webhooks
      if [[ "${PAAS_SKIP_KYVERNO_RESTART:-}" != "1" ]]; then
        restart_kyverno_admission
      else
        echo "SKIP: kyverno restart (PAAS_SKIP_KYVERNO_RESTART=1)"
      fi
      echo "OK: kyverno webhooks cleared after 502 probe"
      exit 0
    fi
    if kyverno_admission_up; then
      echo "OK: kyverno admission service has endpoints"
      exit 0
    fi
    if ! kyverno_webhooks_present; then
      echo "OK: kyverno down but no blocking webhooks registered"
      if [[ "${PAAS_SKIP_KYVERNO_RESTART:-}" != "1" ]]; then
        restart_kyverno_admission
      else
        echo "SKIP: kyverno restart (PAAS_SKIP_KYVERNO_RESTART=1)"
      fi
      exit 0
    fi
    echo "WARN: kyverno admission DOWN but webhooks still registered — removing fail-closed hooks"
    remove_kyverno_webhooks
    if [[ "${PAAS_SKIP_KYVERNO_RESTART:-}" != "1" ]]; then
      restart_kyverno_admission
    else
      echo "SKIP: kyverno restart (PAAS_SKIP_KYVERNO_RESTART=1)"
    fi
    echo "OK: kyverno webhooks cleared (lab fail-open until admission is healthy)"
    ;;
  status)
    if kyverno_admission_up; then
      echo "kyverno: up"
    else
      echo "kyverno: down"
    fi
    if kyverno_webhooks_present; then
      echo "webhooks: present"
    else
      echo "webhooks: none"
    fi
    ;;
  *)
    echo "usage: lab-kyverno-webhook-guard.sh [guard|status]" >&2
    exit 1
    ;;
esac
