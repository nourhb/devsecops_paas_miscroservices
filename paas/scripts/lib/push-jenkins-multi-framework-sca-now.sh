#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
JNS="${JENKINS_K8S_NAMESPACE:-cicd}"
JPOD="${JENKINS_POD:-jenkins-0}"
REMOTE="${JENKINS_PAAS_REMOTE_DIR:-/var/jenkins_home/paas}"
MARKER='Python BOM from requirements.txt (node — works without python3 on agent)'

cd "${REPO_ROOT}"

if grep -qF "${MARKER}" "${REPO_ROOT}/paas/jenkins/Jenkinsfile.paas-deploy" 2>/dev/null; then
  echo "==> Repo has multi-framework SCA — full CPS render + push"
  SKIP_HARBOR_FIX_PUSH=1 bash "${SCRIPT_DIR}/fix-paas-deploy-cps-split-now.sh"
  exit $?
fi

echo "==> Live patch Jenkins pod (repo Jenkinsfile stale on this VM)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

for f in paas-deploy-stages-p2.groovy paas-deploy-stages.groovy; do
  kubectl exec -n "${JNS}" "${JPOD}" -c jenkins -- cat "${REMOTE}/${f}" > "${TMP}/${f}" 2>/dev/null || true
done

python3 <<'PY' "${TMP}/paas-deploy-stages-p2.groovy" "${TMP}/paas-deploy-stages.groovy"
import re, sys
from pathlib import Path

MARKER = "Python BOM from requirements.txt (node — works without python3 on agent)"
NODE_BLOCK = '''
              if [ -f requirements.txt ] && command -v node >/dev/null 2>&1; then
                echo "[sca] Python BOM from requirements.txt (node — works without python3 on agent)"
                node -e "
                  const fs=require('fs');
                  const name=process.env.PROJECT_NAME||'app';
                  const lines=fs.readFileSync('requirements.txt','utf8').split(/\\n/).map(l=>l.trim()).filter(l=>l&&!l.startsWith('#'));
                  const components=lines.map(line=>{
                    const pkg=line.split(/[=<>!\\[]/)[0].trim();
                    return {type:'library',name:pkg,'bom-ref':'pypi:'+pkg+'@unspecified',purl:'pkg:pypi/'+pkg};
                  });
                  fs.mkdirSync('sca',{recursive:true});
                  fs.writeFileSync('sca/bom.json', JSON.stringify({
                    bomFormat:'CycloneDX', specVersion:'1.4', version:1,
                    metadata:{component:{type:'application',name}},
                    components
                  }, null, 2)+'\\n');
                "
              fi
              if [ ! -f sca/bom.json ] && command -v python3 >/dev/null 2>&1; then
                python3 -m pip install --user -q cyclonedx-bom 2>/dev/null || pip3 install --user -q cyclonedx-bom 2>/dev/null || true
              fi
              if [ ! -f sca/bom.json ] && command -v cyclonedx-py >/dev/null 2>&1; then
                if [ -f requirements.txt ]; then
                  cyclonedx-py requirements -i requirements.txt -o sca/bom.json
                else
                  cyclonedx-py environment -o sca/bom.json
                fi
              fi
'''

def patch_groovy(path: Path) -> bool:
    if not path.is_file() or not path.stat().st_size:
        return False
    t = path.read_text(encoding="utf-8")
    if MARKER in t:
        print(f"SKIP {path.name}: already patched")
        return False
    changed = False
    if "ensureNodeTool('20.19.5')" not in t and "def scaPyRoot" in t:
        t2 = re.sub(
            r"(if \(fileExists\(\"\$\{scaPyRoot\}/requirements\.txt\"\)[^\n]+\n)",
            r"ensureNodeTool('20.19.5')\n            \1",
            t,
            count=1,
        )
        if t2 != t:
            t = t2
            changed = True
    old = re.compile(
        r"(mkdir -p sca\n)"
        r"(?:\s*export PROJECT_NAME=[^\n]+\n)?"
        r"\s*if command -v python3 >/dev/null 2>&1; then\n"
        r"\s*python3 -m pip install --user -q cyclonedx-bom[^\n]*\n"
        r"\s*fi\n"
        r"\s*if command -v cyclonedx-py >/dev/null 2>&1; then\n"
        r"\s*if \[ -f requirements\.txt \]; then\n"
        r"\s*cyclonedx-py requirements[^\n]+\n"
        r"\s*else\n"
        r"\s*cyclonedx-py environment[^\n]+\n"
        r"\s*fi\n"
        r"(?:\s*else\n\s*python3 -m pip freeze[^\n]+\n\s*fi\n)?"
        r"\s*test -f sca/bom\.json",
        re.MULTILINE,
    )
    m = old.search(t)
    if m:
        export = ""
        em = re.search(r"\s*export PROJECT_NAME=[^\n]+\n", t[m.start():m.end()])
        if em:
            export = em.group(0)
        repl = m.group(1) + export + NODE_BLOCK + "\n              test -f sca/bom.json"
        t = t[: m.start()] + repl + t[m.end() :]
        changed = True
    if "yarn.lock" in t and "yarn install" not in t.split("yarn.lock")[1][:800]:
        t = t.replace(
            'echo "[sca] cyclonedx-npm (yarn.lock — do not use --package-lock-only)"\n              npx',
            'echo "[sca] yarn.lock — yarn install then cyclonedx-npm"\n'
            '              if ! command -v yarn >/dev/null 2>&1; then corepack enable 2>/dev/null || npm install -g yarn 2>/dev/null || true; fi\n'
            '              if command -v yarn >/dev/null 2>&1; then yarn install --frozen-lockfile 2>/dev/null || yarn install; fi\n'
            '              npx',
            1,
        )
        changed = True
    if changed:
        path.write_text(t, encoding="utf-8")
        print(f"OK patched {path.name}")
        return True
    print(f"WARN: no changes in {path.name}")
    return False

for arg in sys.argv[1:]:
    patch_groovy(Path(arg))
PY

for f in paas-deploy-stages-p2.groovy paas-deploy-stages.groovy; do
  [[ -f "${TMP}/${f}" ]] || continue
  kubectl exec -i -n "${JNS}" "${JPOD}" -c jenkins -- tee "${REMOTE}/${f}" < "${TMP}/${f}" >/dev/null
done

bash "${SCRIPT_DIR}/assemble-paas-deploy-monolith.sh"

kubectl exec -n "${JNS}" "${JPOD}" -c jenkins -- grep -c "${MARKER}" "${REMOTE}/paas-deploy-stages.groovy" \
  | grep -qv '^0$' || { echo "FAIL: monolith missing Python node SCA fix" >&2; exit 1; }

echo ""
echo "OK: multi-framework SCA on ${JNS}/${JPOD}"
echo "Trigger a new paas-deploy build."
