#!/usr/bin/env python3
"""Patch nip-first Harbor crane push → IP-first. Safe to run repeatedly."""
from __future__ import annotations

import re
import sys
from pathlib import Path

IF_ELSE_NIP = re.compile(
    r"[ \t]*if \[ \"\\?\$\{_crane_attempt\}\" -ge 2 \]; then\n"
    r"[ \t]*_push_ref=\"\\?\$\{_push_ref_ip\}\"\n"
    r"[ \t]*echo \"\[image\] crane append using IP registry ref \(401 fallback\): \\?\$\{_push_ref\}\"\n"
    r"[ \t]*else\n"
    r"[ \t]*_push_ref=\"[^\"]+\"\n"
    r"[ \t]*fi\n",
    re.MULTILINE,
)


def patch_text(text: str) -> tuple[str, bool]:
    if "primary push ref (IP)" in text and "401 fallback" not in text:
        return text, False

    orig = text

    text, n = IF_ELSE_NIP.subn('      _push_ref="${_push_ref_ip}"\n', text, count=1)
    if n == 0 and "401 fallback" not in text:
        return text, False

    text = re.sub(
        r"    _push_ref=\"\\?\$\{imageRef\}\"\n    _push_ref_ip=",
        "    _push_ref_ip=",
        text,
        count=1,
    )

    if "primary push ref (IP)" not in text:
        text = re.sub(
            r"(    paas_harbor_ensure_project_and_token \|\| exit 1\n)",
            r'\1    echo "[image] primary push ref (IP): ${imageRefIp} ; alias ref: ${imageRef}"\n',
            text,
            count=1,
        )

    if '_crane_max="${JENKINS_CRANE_PUSH_RETRIES:-3}"\n    _crane_attempt=1' in text:
        text = text.replace(
            '_crane_max="${JENKINS_CRANE_PUSH_RETRIES:-3}"\n    _crane_attempt=1',
            '_crane_max="${JENKINS_CRANE_PUSH_RETRIES:-3}"\n'
            '    if [ "${_crane_max}" -lt 2 ] 2>/dev/null; then _crane_max=2; fi\n'
            "    _crane_attempt=1",
            1,
        )
    if '_crane_max="\\${JENKINS_CRANE_PUSH_RETRIES:-3}"\n    _crane_attempt=1' in text:
        text = text.replace(
            '_crane_max="\\${JENKINS_CRANE_PUSH_RETRIES:-3}"\n    _crane_attempt=1',
            '_crane_max="\\${JENKINS_CRANE_PUSH_RETRIES:-3}"\n'
            '    if [ "\\${_crane_max}" -lt 2 ] 2>/dev/null; then _crane_max=2; fi\n'
            "    _crane_attempt=1",
            1,
        )

    text = text.replace(
        'if [ "\\${_push_ref}" != "${imageRef}" ]; then\n'
        '          echo "[image] pushed via IP ref — tagging nip.io alias ${imageRef}"\n'
        '          "${craneBin}" ${craneInsecure} tag "\\${_push_ref}" "${imageRef}"',
        'if [ "\\${_push_ref_ip}" != "${imageRef}" ]; then\n'
        '          echo "[image] pushed via IP ref — tagging nip.io alias ${imageRef}"\n'
        '          "${craneBin}" ${craneInsecure} tag "\\${_push_ref_ip}" "${imageRef}"',
        1,
    )

    return text, text != orig


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: patch-crane-ip-first.py FILE [FILE...]", file=sys.stderr)
        return 2
    rc = 0
    for arg in sys.argv[1:]:
        p = Path(arg)
        if not p.is_file():
            print(f"skip missing {p}", file=sys.stderr)
            rc = 1
            continue
        raw = p.read_text(encoding="utf-8", errors="replace")
        out, changed = patch_text(raw)
        if "401 fallback" in out:
            print(f"FAIL still has 401 fallback in {p}", file=sys.stderr)
            rc = 1
            continue
        if changed:
            p.write_text(out, encoding="utf-8")
            print(f"OK patched {p}")
        elif "primary push ref (IP)" in out:
            print(f"OK already IP-first {p}")
        else:
            print(f"WARN no change {p}", file=sys.stderr)
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
