#!/usr/bin/env bash
# Mount paas/.lab-cosign/cosign.pub into deployment/frontend at /etc/cosign/cosign.pub (idempotent).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
PAAS_NS="${PAAS_NS:-paas}"
DEPLOY_NAME="${DEPLOY_NAME:-frontend}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${KEYDIR}/cosign.pub" ]] || die "Missing ${KEYDIR}/cosign.pub"
command -v kubectl >/dev/null 2>&1 || die "kubectl required"
kubectl get deployment "${DEPLOY_NAME}" -n "${PAAS_NS}" >/dev/null 2>&1 || die "deployment/${DEPLOY_NAME} not in ${PAAS_NS}"

echo "==> Secret cosign-lab-pub (public key file, not PEM in env)"
kubectl create secret generic cosign-lab-pub \
  --from-file=cosign.pub="${KEYDIR}/cosign.pub" \
  -n "${PAAS_NS}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Patch deployment/${DEPLOY_NAME} — volume + mount + COSIGN_PUBLIC_KEY_PATH"
python3 - "${PAAS_NS}" "${DEPLOY_NAME}" <<'PY'
import json, subprocess, sys

ns, name = sys.argv[1], sys.argv[2]
raw = subprocess.check_output(["kubectl", "get", "deployment", name, "-n", ns, "-o", "json"], text=True)
dep = json.loads(raw)
spec = dep["spec"]["template"]["spec"]
vol_name = "cosign-lab-pub"
mount_path = "/etc/cosign"
key_path = f"{mount_path}/cosign.pub"

vols = spec.setdefault("volumes", [])
if not any(v.get("name") == vol_name for v in vols):
    vols.append({
        "name": vol_name,
        "secret": {
            "secretName": "cosign-lab-pub",
            "defaultMode": 0o444,
            "items": [{"key": "cosign.pub", "path": "cosign.pub"}],
        },
    })

container = next(c for c in spec["containers"] if c.get("name") == name)
mounts = container.setdefault("volumeMounts", [])
if not any(m.get("name") == vol_name for m in mounts):
    mounts.append({"name": vol_name, "mountPath": mount_path, "readOnly": True})

env_list = container.setdefault("env", [])
for env_name, env_val in [
    ("COSIGN_PUBLIC_KEY_PATH", key_path),
    ("COSIGN_ALLOW_INSECURE_REGISTRY", "true"),
]:
    row = next((e for e in env_list if e.get("name") == env_name), None)
    if row:
        row["value"] = env_val
    else:
        env_list.append({"name": env_name, "value": env_val})

subprocess.check_call(["kubectl", "apply", "-f", "-"], input=json.dumps(dep), text=True)
print(f"OK: {name} mounts {key_path} from secret cosign-lab-pub")
PY

kubectl rollout restart "deployment/${DEPLOY_NAME}" -n "${PAAS_NS}"
kubectl rollout status "deployment/${DEPLOY_NAME}" -n "${PAAS_NS}" --timeout=600s

if kubectl exec -n "${PAAS_NS}" "deploy/${DEPLOY_NAME}" -- test -r /etc/cosign/cosign.pub; then
  echo "OK: /etc/cosign/cosign.pub readable in frontend pod"
else
  die "/etc/cosign/cosign.pub not readable after rollout"
fi
