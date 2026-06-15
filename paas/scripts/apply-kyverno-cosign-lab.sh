#!/usr/bin/env bash
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

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "ERROR: missing ${ENV_FILE}" >&2
  exit 1
fi

python3 - "${ENV_FILE}" "${POLICY_SRC}" "${POLICY_OUT}" <<'PY'
import re
import sys
from pathlib import Path
import yaml

env_path, src_path, out_path = sys.argv[1:4]
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

policy = yaml.safe_load(Path(src_path).read_text(encoding="utf-8"))
# Lab only: COSIGN_LAB_ENFORCE_SIGNED (never COSIGN_ENFORCE_SIGNED from PaaS prod config).
enforce = False
for line in text.splitlines():
    if line.startswith("COSIGN_LAB_ENFORCE_SIGNED="):
        v = line.split("=", 1)[1].strip().strip('"').strip("'").lower()
        enforce = v in ("true", "1", "yes")
        break
policy["spec"]["validationFailureAction"] = "Enforce" if enforce else "Audit"
verify = policy["spec"]["rules"][0]["verifyImages"][0]
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
action = policy["spec"]["validationFailureAction"]
print(f"OK wrote {out_path} (HTTP Harbor + harbor-regcred, validationFailureAction={action})")
PY

kubectl apply -f "${POLICY_OUT}"

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
