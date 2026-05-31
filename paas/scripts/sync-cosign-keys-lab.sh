#!/usr/bin/env bash
# Write paas/.lab-cosign/cosign.{key,pub} into docker-compose.env and optionally sync Jenkins + Kyverno.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
ENV_FILE="${ENV_FILE:-${REPO_ROOT}/paas/frontend/docker-compose.env}"
KEYDIR="${REPO_ROOT}/paas/.lab-cosign"
SYNC_JENKINS="${SYNC_JENKINS:-1}"
SYNC_FRONTEND="${SYNC_FRONTEND:-1}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -f "${KEYDIR}/cosign.pub" ]] || die "Missing ${KEYDIR}/cosign.pub — run: COSIGN_PASSWORD=\"\" cosign generate-key-pair --output-key-prefix ${KEYDIR}/cosign"
[[ -f "${KEYDIR}/cosign.key" ]] || die "Missing ${KEYDIR}/cosign.key"
[[ -f "${ENV_FILE}" ]] || die "Missing ${ENV_FILE}"

python3 - "${KEYDIR}/cosign.pub" "${KEYDIR}/cosign.key" "${ENV_FILE}" <<'PY'
import pathlib, re, sys

pub_path, key_path, env_path = sys.argv[1], sys.argv[2], sys.argv[3]
KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
COSIGN_KEYS = frozenset({"COSIGN_PUBLIC_KEY", "COSIGN_PRIVATE_KEY", "COSIGN_PASSWORD"})


def escape_for_compose_line(value: str) -> str:
    escaped = (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r\n", "\n")
        .replace("\r", "\n")
        .replace("\n", "\\n")
        .replace("$", "$$$$")
    )
    return f'"{escaped}"'


def strip_cosign_lines(text: str) -> str:
    kept: list[str] = []
    skip = False
    for line in text.splitlines():
        if any(line.startswith(f"{k}=") for k in COSIGN_KEYS):
            skip = True
            continue
        if skip:
            if KEY_RE.match(line):
                skip = False
            else:
                continue
        kept.append(line)
    return "\n".join(kept).rstrip() + "\n"


def read_env_pem(text: str, key: str) -> str:
    m = re.search(rf'^{re.escape(key)}="((?:[^"\\]|\\.)*)"\s*$', text, re.M)
    if not m:
        return ""
    return m.group(1).replace("\\n", "\n").replace("\\\\", "\\").strip()


text = strip_cosign_lines(pathlib.Path(env_path).read_text(encoding="utf-8"))
pub_pem = pathlib.Path(pub_path).read_text(encoding="utf-8").strip()
priv_pem = pathlib.Path(key_path).read_text(encoding="utf-8").strip()
text = text.rstrip() + "\n"
text += f"COSIGN_PUBLIC_KEY={escape_for_compose_line(pub_pem)}\n"
text += f"COSIGN_PRIVATE_KEY={escape_for_compose_line(priv_pem)}\n"
text += "COSIGN_PASSWORD=\n"
pathlib.Path(env_path).write_text(text, encoding="utf-8")

pub_env = read_env_pem(text, "COSIGN_PUBLIC_KEY")
priv_env = read_env_pem(text, "COSIGN_PRIVATE_KEY")
if pub_env != pub_pem or priv_env != priv_pem:
    raise SystemExit("ERROR: env write verification failed")
print("OK: COSIGN_* keys written as single-line quoted values (safe to source)")
PY

export COSIGN_PASSWORD=""
if ! cosign public-key --key "${KEYDIR}/cosign.key" >/dev/null 2>&1; then
  die "cosign.key does not decrypt with COSIGN_PASSWORD= — regenerate keys or set COSIGN_PASSWORD in ${ENV_FILE}"
fi
echo "OK: cosign.key decrypts with empty COSIGN_PASSWORD (lab default)"

if command -v kubectl >/dev/null 2>&1 && kubectl get ns cicd >/dev/null 2>&1; then
  JENKINS_POD="$(kubectl get pod -n cicd -l app=jenkins -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${JENKINS_POD}" ]]; then
    kubectl exec -n cicd "${JENKINS_POD}" -- mkdir -p /var/jenkins_home/cosign-lab /var/jenkins_home/bin 2>/dev/null || true
    kubectl cp "${KEYDIR}/cosign.key" "cicd/${JENKINS_POD}:/var/jenkins_home/cosign-lab/cosign.key"
    kubectl exec -n cicd "${JENKINS_POD}" -- chmod 600 /var/jenkins_home/cosign-lab/cosign.key
    if command -v cosign >/dev/null 2>&1; then
      kubectl cp "$(command -v cosign)" "cicd/${JENKINS_POD}:/var/jenkins_home/bin/cosign" 2>/dev/null || true
      kubectl exec -n cicd "${JENKINS_POD}" -- chmod +x /var/jenkins_home/bin/cosign 2>/dev/null || true
    fi
    echo "OK: Jenkins pod has /var/jenkins_home/cosign-lab/cosign.key (Step 9 lab fallback)"
  fi
fi

if kubectl get crd clusterpolicies.kyverno.io >/dev/null 2>&1; then
  python3 - "${KEYDIR}/cosign.pub" "${REPO_ROOT}/paas/k8s-manifests/kyverno/require-signed-images.yaml" <<'PY'
import pathlib, sys
pub = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
body = "\n".join(line for line in pub.splitlines() if "BEGIN" not in line and "END" not in line).strip()
tpl = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
out = tpl.replace("REPLACE_WITH_REAL_COSIGN_PUBLIC_KEY", body)
pathlib.Path(sys.argv[2]).parent.joinpath(".require-signed-images.lab.yaml").write_text(out, encoding="utf-8")
PY
  kubectl apply -f "${REPO_ROOT}/paas/k8s-manifests/kyverno/.require-signed-images.lab.yaml" 2>/dev/null || true
  echo "OK: Kyverno require-signed-images updated"
fi

if [[ "${SYNC_FRONTEND}" == "1" ]]; then
  if ! grep -q '^COSIGN_ALLOW_INSECURE_REGISTRY=' "${ENV_FILE}" 2>/dev/null; then
    echo 'COSIGN_ALLOW_INSECURE_REGISTRY=true' >> "${ENV_FILE}"
  fi
  bash "${SCRIPT_DIR}/wire-harbor-cluster-registry-lab.sh" "${ENV_FILE}" || true
  ENV_FILE="${ENV_FILE}" bash "${SCRIPT_DIR}/sync-paas-frontend-env-k8s.sh"
  bash "${SCRIPT_DIR}/mount-cosign-pub-frontend-lab.sh"
  bash "${SCRIPT_DIR}/wire-harbor-docker-auth-frontend-lab.sh"
fi

if [[ "${SYNC_JENKINS}" == "1" ]]; then
  # create_jenkins_paas_deploy_job.py loads docker-compose.env itself — do not `source` PEM keys.
  python3 "${SCRIPT_DIR}/create_jenkins_paas_deploy_job.py" --force --force-full
fi

if kubectl get deployment frontend -n paas >/dev/null 2>&1; then
  PEM_HEAD="$(kubectl exec -n paas deploy/frontend -- sh -c 'printf "%s" "$COSIGN_PUBLIC_KEY" | head -c 24' 2>/dev/null || true)"
  if [[ "${PEM_HEAD}" == '"-----BEGIN PUBLIC KEY' ]]; then
    echo "WARN: COSIGN_PUBLIC_KEY in frontend pod still has literal quote prefix — re-run: bash paas/scripts/sync-paas-frontend-env-k8s.sh"
  elif [[ "${PEM_HEAD}" == '-----BEGIN PUBLIC KEY'-* ]]; then
    echo "OK: COSIGN_PUBLIC_KEY in frontend pod looks like valid PEM (no outer quotes)"
  fi
fi

echo ""
echo "One-command lab fix (Cosign + Security UI + sign latest image):"
echo "  bash paas/scripts/finalize-devsecops-security-lab.sh"
echo ""
echo "Or trigger ONE deploy after sync:"
echo "  PROJECT_ID=<uuid> python3 paas/scripts/trigger-paas-deploy-lab.py"
echo "After SUCCESS, verify Step 9 then:"
echo "  cosign verify --key ${KEYDIR}/cosign.pub --allow-insecure-registry 192.168.56.129:30002/paas/simple-app:<build#>"
