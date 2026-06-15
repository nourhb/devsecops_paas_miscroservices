#!/usr/bin/env bash
# Lab Kyverno cosign policy: HTTP Harbor creds + public key from env.
# Enforce mode ONLY when shell exports COSIGN_LAB_ENFORCE_SIGNED=true (not docker-compose COSIGN_ENFORCE_SIGNED).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
POLICY_SRC="${REPO_ROOT}/paas/k8s-manifests/kyverno/require-signed-images.yaml"
POLICY_OUT="${REPO_ROOT}/paas/k8s-manifests/kyverno/.require-signed-images.lab.yaml"
NODE_IP="${NODE_IP:-192.168.56.129}"
HARBOR_NODEPORT="${HARBOR_NODEPORT:-30002}"
HARBOR_HOST="harbor.${NODE_IP}.nip.io"
HARBOR_REGISTRY="${HARBOR_HOST}:${HARBOR_NODEPORT}"
HARBOR_USER="${HARBOR_USER:-admin}"
HARBOR_PASS="${HARBOR_PASS:-Harbor12345}"
KYVERNO_NS="${KYVERNO_NS:-kyverno}"
# Shell env only — default Audit so PaaS deploys are never blocked in lab unless explicitly opted in.
LAB_ENFORCE="${COSIGN_LAB_ENFORCE_SIGNED:-false}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: missing ${ENV_FILE}" >&2
  exit 1
fi

ACTION="$(python3 - "${ENV_FILE}" "${POLICY_SRC}" "${POLICY_OUT}" "${LAB_ENFORCE}" <<'PY'
import re
import sys
from pathlib import Path
import yaml

env_path, src_path, out_path, lab_enforce = sys.argv[1:5]
text = Path(env_path).read_text(encoding="utf-8")
raw = ""
for line in text.splitlines():
    if line.startswith("COSIGN_PUBLIC_KEY="):
        raw = line.split("=", 1)[1].strip().strip('"').strip("'")
if not raw:
    raise SystemExit("COSIGN_PUBLIC_KEY not set in env file")
if "\\n" in raw and "\n" not in raw:
    raw = raw.replace("\\n", "\n")
raw = raw.strip()
if "BEGIN PUBLIC KEY" not in raw:
    body = re.sub(r"\s+", "", raw)
    raw = f"-----BEGIN PUBLIC KEY-----\n{body}\n-----END PUBLIC KEY-----"

enforce = lab_enforce.strip().lower() in ("true", "1", "yes")
policy = yaml.safe_load(Path(src_path).read_text(encoding="utf-8"))
policy["spec"]["validationFailureAction"] = "Enforce" if enforce else "Audit"
verify = policy["spec"]["rules"][0]["verifyImages"][0]
# Kyverno rejects Audit + mutateDigest:true (admission webhook validate-policy).
verify["mutateDigest"] = True if enforce else False
verify["imageRegistryCredentials"] = {
    "allowInsecureRegistry": True,
    "secrets": ["harbor-regcred"],
}
keys = verify["attestors"][0]["entries"][0]["keys"]
keys["publicKeys"] = raw
keys.setdefault("rekor", {})["ignoreTlog"] = True
keys.setdefault("ctlog", {})["ignoreSCT"] = True

out = Path(out_path)
out.write_text(yaml.safe_dump(policy, default_flow_style=False, sort_keys=False), encoding="utf-8")
yaml.safe_load(out.read_text(encoding="utf-8"))
print(policy["spec"]["validationFailureAction"])
PY
)"

apply_cluster_policy() {
  # Strategic merge apply can leave mutateDigest:true when switching Enforce→Audit.
  if kubectl get clusterpolicy require-signed-images >/dev/null 2>&1; then
    kubectl replace -f "${POLICY_OUT}" --force
  else
    kubectl apply -f "${POLICY_OUT}"
  fi
}

patch_lab_kyverno_mode() {
  local md="false"
  [[ "${ACTION}" == "Enforce" ]] && md="true"
  kubectl patch clusterpolicy require-signed-images --type=json -p="[
    {\"op\":\"replace\",\"path\":\"/spec/validationFailureAction\",\"value\":\"${ACTION}\"},
    {\"op\":\"replace\",\"path\":\"/spec/rules/0/verifyImages/0/mutateDigest\",\"value\":${md}}
  ]"
}

# Enforce→Audit fails apply while mutateDigest stays true — patch live policy first.
if [[ "${ACTION}" == "Audit" ]] && kubectl get clusterpolicy require-signed-images >/dev/null 2>&1; then
  CURRENT_ACTION="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
  CURRENT_MD="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.rules[0].verifyImages[0].mutateDigest}' 2>/dev/null || true)"
  if [[ "${CURRENT_ACTION}" != "Audit" ]] || [[ "${CURRENT_MD}" == "true" ]]; then
    echo "==> Pre-patch Kyverno Audit + mutateDigest=false"
    patch_lab_kyverno_mode
  fi
fi

if ! apply_cluster_policy 2>/dev/null; then
  echo "WARN: kubectl replace failed — patching live policy in place (Audit needs mutateDigest=false)" >&2
  patch_lab_kyverno_mode
fi

CURRENT_ACTION="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
CURRENT_MD="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.rules[0].verifyImages[0].mutateDigest}' 2>/dev/null || true)"
EXPECTED_MD="false"
[[ "${ACTION}" == "Enforce" ]] && EXPECTED_MD="true"
if [[ "${CURRENT_ACTION}" != "${ACTION}" ]] || [[ "${CURRENT_MD}" != "${EXPECTED_MD}" ]]; then
  echo "WARN: policy drift (action=${CURRENT_ACTION:-?} mutateDigest=${CURRENT_MD:-?}) — patching" >&2
  patch_lab_kyverno_mode
fi
CURRENT_ACTION="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.validationFailureAction}' 2>/dev/null || true)"
CURRENT_MD="$(kubectl get clusterpolicy require-signed-images -o jsonpath='{.spec.rules[0].verifyImages[0].mutateDigest}' 2>/dev/null || true)"
if [[ "${CURRENT_ACTION}" != "${ACTION}" ]]; then
  echo "ERROR: require-signed-images validationFailureAction=${CURRENT_ACTION:-?} (wanted ${ACTION})" >&2
  exit 1
fi
echo "OK wrote ${POLICY_OUT} (validationFailureAction=${CURRENT_ACTION}, mutateDigest=${CURRENT_MD}, COSIGN_LAB_ENFORCE_SIGNED=${LAB_ENFORCE})"

kubectl create namespace "${KYVERNO_NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret docker-registry harbor-regcred -n "${KYVERNO_NS}" \
  --docker-server="${HARBOR_REGISTRY}" \
  --docker-username="${HARBOR_USER}" \
  --docker-password="${HARBOR_PASS}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

for dep in kyverno-admission-controller kyverno-background-controller kyverno-reports-controller; do
  if ! kubectl get deploy "${dep}" -n "${KYVERNO_NS}" >/dev/null 2>&1; then
    continue
  fi
  args="$(kubectl get deploy "${dep}" -n "${KYVERNO_NS}" -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || echo "[]")"
  if ! grep -q allowInsecureRegistry <<<"${args}"; then
    kubectl patch deployment "${dep}" -n "${KYVERNO_NS}" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--allowInsecureRegistry"}]' 2>/dev/null || true
  fi
  if [[ "${dep}" == "kyverno-admission-controller" ]] && ! grep -q imagePullSecrets <<<"${args}"; then
    kubectl patch deployment "${dep}" -n "${KYVERNO_NS}" --type=json \
      -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--imagePullSecrets=harbor-regcred"}]' 2>/dev/null || true
  fi
  kubectl rollout status deployment/"${dep}" -n "${KYVERNO_NS}" --timeout=120s 2>/dev/null || true
done
echo "OK: Kyverno policy + HTTP Harbor registry credentials"
