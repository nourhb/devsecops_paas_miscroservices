#!/usr/bin/env bash
set -euo pipefail

IMAGE="${1:?usage: lab-k3s-import-image-nodes.sh <image-ref>}"
SSH_USER="${SSH_USER:-master}"
CTR_NS="${CTR_NS:-k8s.io}"

import_local() {
  if command -v k3s >/dev/null 2>&1; then
    docker save "${IMAGE}" | sudo k3s ctr -n "${CTR_NS}" images import -
  elif command -v ctr >/dev/null 2>&1; then
    docker save "${IMAGE}" | sudo ctr -n "${CTR_NS}" images import -
  else
    echo "ERROR: no k3s/ctr on this host" >&2
    return 1
  fi
}

import_remote() {
  local node="$1"
  echo "==> Import ${IMAGE} on node ${node}"
  docker save "${IMAGE}" | ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no \
    "${SSH_USER}@${node}" "sudo k3s ctr -n ${CTR_NS} images import -" 2>/dev/null
}

echo "==> Import ${IMAGE} to all k3s nodes"
import_local
while IFS= read -r node; do
  [[ -z "${node}" ]] && continue
  [[ "${node}" == "$(hostname -s 2>/dev/null || hostname)" ]] && continue
  import_remote "${node}" || echo "WARN: import failed on ${node} (ssh ${SSH_USER}@${node}?)" >&2
done < <(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n')

echo "OK: image import attempted on all nodes"
