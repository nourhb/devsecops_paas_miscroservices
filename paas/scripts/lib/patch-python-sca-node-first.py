#!/usr/bin/env python3
"""Patch Jenkins groovy: Python SCA uses Node requirements.txt BOM when python3 missing."""
from __future__ import annotations

import re
import sys
from pathlib import Path

MARKER = "Python BOM from requirements.txt (node — works without python3 on agent)"

NODE_BLOCK = r'''
              if [ -f requirements.txt ] && command -v node >/dev/null 2>&1; then
                echo "[sca] Python BOM from requirements.txt (node — works without python3 on agent)"
                node -e "
                  const fs=require('fs');
                  const name=process.env.PROJECT_NAME||'app';
                  const lines=fs.readFileSync('requirements.txt','utf8').split(/\n/).map(l=>l.trim()).filter(l=>l&&!l.startsWith('#'));
                  const components=lines.map(line=>{
                    const pkg=line.split(/[=<>!\[]/)[0].trim();
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

OLD = re.compile(
    r"mkdir -p sca\n"
    r"(?:\s*export PROJECT_NAME=.*\n)?"
    r"\s*if command -v python3 >/dev/null 2>&1; then\n"
    r"\s*python3 -m pip install --user -q cyclonedx-bom.*?\n"
    r"\s*fi\n"
    r"\s*if command -v cyclonedx-py >/dev/null 2>&1; then\n"
    r"\s*if \[ -f requirements\.txt \]; then\n"
    r"\s*cyclonedx-py requirements -i requirements\.txt -o sca/bom\.json\n"
    r"\s*else\n"
    r"\s*cyclonedx-py environment -o sca/bom\.json\n"
    r"\s*fi\n"
    r"\s*else\n"
    r"\s*python3 -m pip freeze.*?\n"
    r"\s*fi\n"
    r"\s*test -f sca/bom\.json",
    re.MULTILINE,
)


def main() -> int:
    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8")
    if MARKER in text:
        print(f"SKIP: {path.name} already has node-first Python SCA")
        return 0
    if "Python SBOM missing" not in text and "cyclonedx-py requirements" not in text:
        print(f"SKIP: {path.name} — no Python SCA block found")
        return 0
    m = OLD.search(text)
    if not m:
        inj = re.compile(
            r"(mkdir -p sca\n)(\s*export PROJECT_NAME=.*\n)?",
            re.MULTILINE,
        )
        im = inj.search(text)
        if not im:
            print(f"FAIL: could not locate Python SCA mkdir in {path.name}", file=sys.stderr)
            return 1
        export = im.group(2) or ""
        repl = im.group(1) + export + NODE_BLOCK + "\n              test -f sca/bom.json"
        text2 = text[: im.start()] + repl + text[im.end() + len("test -f sca/bom.json") :]
    else:
        export_m = re.search(r"\s*export PROJECT_NAME=.*\n", text[m.start() : m.end()])
        export = export_m.group(0) if export_m else ""
        repl = "mkdir -p sca\n" + export + NODE_BLOCK + "\n              test -f sca/bom.json"
        text2 = text[: m.start()] + repl + text[m.end() :]
    if "ensureNodeTool('20.19.5')" not in text2 and "def scaPyRoot" in text2:
        text2 = text2.replace(
            "if (fileExists(\"${scaPyRoot}/requirements.txt\") || fileExists(\"${scaPyRoot}/pyproject.toml\")) {",
            "if (fileExists(\"${scaPyRoot}/requirements.txt\") || fileExists(\"${scaPyRoot}/pyproject.toml\")) {\n            ensureNodeTool('20.19.5')",
            1,
        )
    path.write_text(text2, encoding="utf-8")
    print(f"OK: patched {path.name} (node-first Python SCA)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
