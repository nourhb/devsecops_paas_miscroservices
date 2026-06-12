#!/usr/bin/env python3
"""Render require-signed-images ClusterPolicy with lab cosign public key (YAML-safe indentation)."""
from __future__ import annotations

import pathlib
import sys

PLACEHOLDER_BLOCK = """                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      REPLACE_WITH_REAL_COSIGN_PUBLIC_KEY
                      -----END PUBLIC KEY-----"""


def render(pub_path: pathlib.Path, tpl_path: pathlib.Path, out_path: pathlib.Path) -> None:
    pub = pub_path.read_text(encoding="utf-8").strip()
    tpl = tpl_path.read_text(encoding="utf-8")
    if PLACEHOLDER_BLOCK not in tpl:
        raise SystemExit(f"ERROR: template missing placeholder block in {tpl_path}")
    indent = "                      "
    pem_block = "\n".join(f"{indent}{line}" for line in pub.splitlines())
    rendered = tpl.replace(PLACEHOLDER_BLOCK, f"                    publicKeys: |-\n{pem_block}")
    out_path.write_text(rendered, encoding="utf-8")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit(f"usage: {sys.argv[0]} <cosign.pub> <require-signed-images.yaml> <out.yaml>")
    render(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]))


if __name__ == "__main__":
    main()
