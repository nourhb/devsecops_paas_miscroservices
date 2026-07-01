#!/usr/bin/env bash
# Fix duplicate def runPaasDeploy() in paas-deploy-stages.groovy (runs Python on HOST — Jenkins pod has no python3).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JENKINS_NS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
JCONTAINER="${JENKINS_CONTAINER:-jenkins}"
REMOTE="${JENKINS_PAAS_REMOTE:-/var/jenkins_home/paas/paas-deploy-stages.groovy}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/paas-dedupe.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

ok() { echo "OK: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || fail "kubectl required"
command -v python3 >/dev/null 2>&1 || fail "python3 required on host (not inside Jenkins pod)"

echo "==> Pull ${REMOTE} from ${JENKINS_NS}/${JPOD}"
kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s \
  cat "${REMOTE}" > "${WORK}/stages.groovy"
[[ -s "${WORK}/stages.groovy" ]] || fail "empty or missing ${REMOTE}"

echo "==> Dedupe runPaasDeploy() on host"
python3 - "${WORK}/stages.groovy" <<'PY'
import sys
from pathlib import Path

p = Path(sys.argv[1])
text = p.read_text(encoding="utf-8")
marker = "def runPaasDeploy() {"
count = text.count(marker)
if count <= 1:
    print(f"OK: {count} runPaasDeploy() — no change")
    sys.exit(0)

def end_of_block(s: str, start: int) -> int:
    depth = 0
    for i in range(start, len(s)):
        c = s[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i + 1
    raise ValueError("unbalanced braces in runPaasDeploy block")


out = text
while out.count(marker) > 1:
    first = out.find(marker)
    first_end = end_of_block(out, first + len(marker) - 1)
    second = out.find(marker, first_end)
    if second < 0:
        break
    second_end = end_of_block(out, second + len(marker) - 1)
    out = out[:second] + out[second_end:]
    print(f"removed duplicate at offset {second}")

if not out.rstrip().endswith("return this"):
    out = out.rstrip() + "\nreturn this\n"

bundle = "helm-portable-20260620-cps-split"
if bundle not in out:
    out = f"// STAGES_BUNDLE_VERSION={bundle}\n// CPS_MONOLITH=h1+h2+h3+vars+p1+p2+p3\n" + out.lstrip()
    print(f"OK: prepended STAGES_BUNDLE_VERSION={bundle}")

p.write_text(out, encoding="utf-8")
final = out.count(marker)
if final != 1:
    sys.exit(f"ERROR: expected 1 runPaasDeploy(), found {final}")
if bundle not in out:
    sys.exit(f"ERROR: missing {bundle} marker after fix")
if "def coerceHarborHostForCosign" not in out:
    sys.exit("ERROR: missing helpers — run restore-paas-deploy-working.sh")
print(f"OK: deduped to 1 runPaasDeploy() ({len(out)} bytes); marker={bundle}")
PY

echo "==> Push fixed monolith to pod"
kubectl exec -i -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=120s -- \
  tee "${REMOTE}" < "${WORK}/stages.groovy" >/dev/null

count="$(kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  grep -c 'def runPaasDeploy()' "${REMOTE}" | tr -d '\r\n')"
[[ "${count}" == "1" ]] || fail "pod still has ${count} runPaasDeploy() — run: bash paas/scripts/lib/restore-paas-deploy-working.sh"

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  grep -qF 'helm-portable-20260620-cps-split' "${REMOTE}" \
  || fail "pod missing helm-portable-20260620-cps-split — re-run this script"

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  grep -qF 'def coerceHarborHostForCosign' "${REMOTE}" \
  || fail "helpers missing — run: bash paas/scripts/lib/restore-paas-deploy-working.sh"

kubectl exec -n "${JENKINS_NS}" "${JPOD}" -c "${JCONTAINER}" --request-timeout=60s \
  tail -1 "${REMOTE}" | grep -qF 'return this' \
  || fail "pod monolith must end with return this"

if [[ -f "${SCRIPT_DIR}/apply-jenkins-inline-steps-wrapper.py" ]]; then
  echo "==> Sync job wrapper"
  python3 "${SCRIPT_DIR}/apply-jenkins-inline-steps-wrapper.py" || true
fi

ok "paas-deploy-stages.groovy has exactly 1 runPaasDeploy() — trigger NEW build (not Replay)"
