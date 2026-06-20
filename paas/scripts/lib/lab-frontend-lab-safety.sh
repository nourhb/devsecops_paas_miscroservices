#!/usr/bin/env bash
# Lab-safe frontend deployment: prevent pod storms (Recreate, master pin, local image Never).
set -euo pipefail

PAAS_NS="${PAAS_NS:-paas}"
LAB_FRONTEND_NODE="${LAB_FRONTEND_NODE:-master}"
DB_URL='postgresql://postgres:root@postgres:5432/paas?options=-c%20lc_messages%3DC'

frontend_pod_count() {
  kubectl get pods -n "${PAAS_NS}" -l app=frontend --no-headers --request-timeout=20s 2>/dev/null \
    | wc -l | tr -d ' '
}

frontend_storm_active() {
  local n="${1:-3}"
  local c
  c="$(frontend_pod_count)"
  [[ "${c}" =~ ^[0-9]+$ ]] && (( c > n ))
}

is_local_lab_frontend_image() {
  local img="${1:-}"
  [[ -z "${img}" ]] && img="$(kubectl get deployment frontend -n "${PAAS_NS}" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  [[ "${img}" == docker.io/library/paas-frontend:* \
    || "${img}" == paas-frontend:* \
    || "${img}" == *paas-frontend:local-* \
    || "${img}" == *paas-frontend:recovery* ]]
}

resolve_lab_image_pull_policy() {
  local img="$1"
  if is_local_lab_frontend_image "${img}"; then
    echo "Never"
  else
    echo "IfNotPresent"
  fi
}

image_in_containerd() {
  local img="$1" short
  short="${img##*/}"
  sudo k3s ctr -n k8s.io images ls 2>/dev/null | grep -qF "${short}" \
    || sudo k3s crictl images 2>/dev/null | grep -qF "${short}"
}

import_docker_image_to_k3s() {
  local img="$1"
  docker image inspect "${img}" >/dev/null 2>&1 || return 1
  # ctr import writes progress to stdout — must not leak into $(resolve_lab_frontend_image).
  docker save "${img}" | sudo k3s ctr -n k8s.io images import - >/dev/null 2>&1
}

resolve_lab_frontend_image() {
  local img="${1:-}"
  local recovery="docker.io/library/paas-frontend:recovery"
  if [[ -z "${img}" ]]; then
    img="$(kubectl get deployment frontend -n "${PAAS_NS}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi
  [[ -n "${img}" ]] || { echo "${recovery}"; return; }

  if image_in_containerd "${img}"; then
    echo "${img}"
    return
  fi

  if import_docker_image_to_k3s "${img}" && image_in_containerd "${img}"; then
    if [[ "${img}" == *paas-frontend:local-* ]]; then
      docker tag "${img}" "${recovery}" 2>/dev/null || true
      import_docker_image_to_k3s "${recovery}" || true
      echo "${recovery}"
      return
    fi
    echo "${img}"
    return
  fi

  import_docker_image_to_k3s "${recovery}" >/dev/null 2>&1 || true
  if image_in_containerd "${recovery}"; then
    echo "${recovery}"
    return
  fi

  echo "${img}"
}

# Stop runaway rollouts before patching (hundreds of pods on worker1).
stop_frontend_storm_if_needed() {
  local threshold="${1:-3}"
  if ! frontend_storm_active "${threshold}"; then
    return 0
  fi
  local c
  c="$(frontend_pod_count)"
  echo "WARN: frontend pod storm (${c} pods) — scaling to 0 and clearing ReplicaSets"
  kubectl rollout pause deployment/frontend -n "${PAAS_NS}" 2>/dev/null || true
  kubectl scale deployment/frontend -n "${PAAS_NS}" --replicas=0 --request-timeout=45s 2>/dev/null || true
  kubectl get rs -n "${PAAS_NS}" -l app=frontend -o name --request-timeout=30s 2>/dev/null \
    | xargs -r kubectl delete --request-timeout=45s --wait=false 2>/dev/null || true
  kubectl delete pods -n "${PAAS_NS}" -l app=frontend --force --grace-period=0 --wait=false \
    --request-timeout=30s 2>/dev/null || true
}

# Pin PaaS UI on master, Recreate strategy (never RollingUpdate), revisionHistoryLimit 0.
apply_lab_frontend_safety() {
  local img="${1:-}"
  local replicas="${2:-1}"
  if [[ -z "${img}" ]]; then
    img="$(kubectl get deployment frontend -n "${PAAS_NS}" \
      -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
  fi
  [[ -n "${img}" ]] || { echo "ERROR: no frontend image" >&2; return 1; }

  img="$(resolve_lab_frontend_image "${img}")"
  img="${img//$'\n'/}"
  img="${img%%[[:space:]]*}"
  [[ "${img}" == docker.io/library/paas-frontend:* ]] || img="docker.io/library/paas-frontend:recovery"

  local pull_policy
  pull_policy="$(resolve_lab_image_pull_policy "${img}")"

  stop_frontend_storm_if_needed 3

  local patch_json
  patch_json="$(python3 - "${img}" "${pull_policy}" "${replicas}" "${LAB_FRONTEND_NODE}" <<'PY'
import json
import sys

img, pull_policy, replicas, node = sys.argv[1:5]
print(json.dumps({
    "spec": {
        "paused": False,
        "revisionHistoryLimit": 0,
        "replicas": int(replicas),
        "strategy": {"type": "Recreate"},
        "progressDeadlineSeconds": 600,
        "template": {
            "spec": {
                "nodeSelector": {"kubernetes.io/hostname": node},
                "tolerations": [{
                    "key": "node.kubernetes.io/disk-pressure",
                    "operator": "Exists",
                    "effect": "NoSchedule",
                }],
                "containers": [{
                    "name": "frontend",
                    "image": img,
                    "imagePullPolicy": pull_policy,
                }],
            }
        },
    }
}))
PY
)"

  kubectl patch deployment frontend -n "${PAAS_NS}" --type=merge --request-timeout=60s -p "${patch_json}" || return 1

  echo "OK: frontend safety — Recreate, replicas=${replicas}, node=${LAB_FRONTEND_NODE}, pull=${pull_policy}, image=${img}"
}

ensure_lab_frontend_safety() {
  if ! kubectl get deployment frontend -n "${PAAS_NS}" >/dev/null 2>&1; then
    return 0
  fi
  local strategy ns strategy_ok=0
  strategy="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.strategy.type}' 2>/dev/null || true)"
  ns="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.nodeSelector.kubernetes\.io/hostname}' 2>/dev/null || true)"
  [[ "${strategy}" == "Recreate" ]] && strategy_ok=1
  if [[ "${strategy_ok}" -eq 1 && "${ns}" == "${LAB_FRONTEND_NODE}" ]]; then
    local img policy want resolved
    img="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    policy="$(kubectl get deployment frontend -n "${PAAS_NS}" -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}' 2>/dev/null || true)"
    want="$(resolve_lab_image_pull_policy "${img}")"
    resolved="$(resolve_lab_frontend_image "${img}")"
    if [[ "${policy}" == "${want}" && "${resolved}" == "${img}" ]] \
        && image_in_containerd "${img}" && ! frontend_storm_active 3; then
      return 0
    fi
  fi
  apply_lab_frontend_safety
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-apply}" in
    apply) ensure_lab_frontend_safety ;;
    storm) stop_frontend_storm_if_needed "${2:-3}" ;;
    count) frontend_pod_count ;;
    *)
      echo "usage: lab-frontend-lab-safety.sh [apply|storm|count]" >&2
      exit 1
      ;;
  esac
fi
