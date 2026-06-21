#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

MARKER = "cps-split-dockerless-6abc-20260620"


def main() -> int:
    path = Path(__file__).resolve().parent / "Jenkinsfile.paas-deploy"
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n")
    if MARKER in text:
        print(f"SKIP: {path.name} already has {MARKER}")
        return 0
    start = text.index("def dockerlessImagePush(String craneBin, String imageRef, String dockerfilePath) {")
    s6a = text.index('  println "[image] Step 6a — npm deps', start)
    s6b = text.index('  println "[image] Step 6b — Next.js production build', start)
    verify = text.index("  verifyNextPublicEnvInBuild(appRoot)", start)
    s6c = text.index('  println "[image] Step 6c — layer tar + crane append', start)
    end_fn = text.index("\n}\n\ndef cosignSignImageShellSnippet", start)

    block_6a = text[s6a:s6b].rstrip() + "\n"
    block_6b = text[s6b:verify].rstrip() + "\n"
    block_6c = text[s6c:end_fn].rstrip() + "\n"

    def wrap(name: str, params: str, body: str) -> str:
        indented = body.replace("\n", "\n")
        return f"def {name}({params}) {{\n{indented}\n}}\n\n"

    helpers = (
        f"// {MARKER}\n"
        + wrap(
            "dockerlessImagePushCraneNode6a",
            "String appRoot",
            block_6a.replace("\n", "\n"),
        )
        + wrap(
            "dockerlessImagePushCraneNode6b",
            "String appRoot, String imageStack",
            block_6b.replace("\n", "\n"),
        )
        + wrap(
            "dockerlessImagePushCraneNode6c",
            "String craneBin, String imageRef, String artifactImageRef, String craneInsecure, String appRoot",
            block_6c.replace("\n", "\n"),
        )
    )

    insert_at = start
    new_middle = (
        "  dockerlessImagePushCraneNode6a(appRoot)\n"
        "  dockerlessImagePushCraneNode6b(appRoot, imageStack)\n"
        "  verifyNextPublicEnvInBuild(appRoot)\n"
        "  dockerlessImagePushCraneNode6c(craneBin, imageRef, artifactImageRef, craneInsecure, appRoot)\n"
    )

    out = text[:insert_at] + helpers + text[insert_at:s6a] + new_middle + text[end_fn:]
    path.write_text(out, encoding="utf-8")
    print(f"OK: split dockerlessImagePush 6a/6b/6c in {path.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
