#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
POLICY_SRC="${REPO_ROOT}/paas/k8s-manifests/kyverno/require-signed-images.yaml"
POLICY_OUT="${REPO_ROOT}/paas/k8s-manifests/kyverno/.require-signed-images.lab.yaml"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: missing ${ENV_FILE}" >&2
  exit 1
fi

read_cosign_public_key() {
  local raw
  raw="$(grep -E '^COSIGN_PUBLIC_KEY=' "${ENV_FILE}" | tail -1 | cut -d= -f2- | tr -d '\r"')"
  if [[ -z "${raw}" ]]; then
    echo "ERROR: COSIGN_PUBLIC_KEY not set in ${ENV_FILE}" >&2
    exit 1
  fi
  printf '%b' "${raw}"
}

PUBKEY="$(read_cosign_public_key)"
export PAAS_COSIGN_PUBKEY_FOR_POLICY="${PUBKEY}"
python3 - "${POLICY_SRC}" "${POLICY_OUT}" <<'PY'
import os
import sys
from pathlib import Path
src, out = sys.argv[1:3]
pubkey = os.environ.get("PAAS_COSIGN_PUBKEY_FOR_POLICY", "").strip()
if not pubkey:
    raise SystemExit("COSIGN_PUBLIC_KEY empty")
text = Path(src).read_text(encoding="utf-8")
inner = pubkey
if "BEGIN PUBLIC KEY" in pubkey:
    inner = "\n".join(
        line.strip() for line in pubkey.splitlines()
        if line.strip() and not line.strip().startswith("-----")
    )
text = text.replace("REPLACE_WITH_REAL_COSIGN_PUBLIC_KEY", inner)
Path(out).write_text(text, encoding="utf-8")
print(f"OK wrote {out}")
PY
unset PAAS_COSIGN_PUBKEY_FOR_POLICY

kubectl apply -f "${POLICY_OUT}"

kubectl create namespace "${KYVERNO_NS}" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret docker-registry harbor-regcred -n "${KYVERNO_NS}" \
  --docker-server="${NODE_IP}:${HARBOR_NODEPORT}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

dep=kyverno-admission-controller
if kubectl get deploy "${dep}" -n "${KYVERNO_NS}" >/dev/null 2>&1; then
  args="$(kubectl get deploy "${dep}" -n "${KYVERNO_NS}" -o jsonpath='{.spec.template.spec.containers[0].args}' || true)"
  if ! grep -q imagePullSecrets <<<"${args}"; then
    kubectl patch deployment "${dep}" -n "${KYVERNO_NS}" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--imagePullSecrets=harbor-regcred"}]' || true
  fi
  if ! grep -q allowInsecureRegistry <<<"${args}"; then
    kubectl patch deployment "${dep}" -n "${KYVERNO_NS}" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--allowInsecureRegistry"}]' || true
  fi
  kubectl rollout status deployment/"${dep}" -n "${KYVERNO_NS}" --timeout=120s || true
fi
