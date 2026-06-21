#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

BUNDLE_MARKER = "helm-portable-20260620-cps-split"
LEGACY_MARKER = "helm-portable-20260619"

HELPER_FILES = (
    "paas-deploy-load-h1.groovy",
    "paas-deploy-load-h2.groovy",
    "paas-deploy-load-h3.groovy",
)
STAGE_FILES = (
    "paas-deploy-stages-vars.groovy",
    "paas-deploy-stages-p1.groovy",
    "paas-deploy-stages-p2.groovy",
    "paas-deploy-stages-p3.groovy",
)
LOAD_FILES = HELPER_FILES + STAGE_FILES + ("paas-deploy-stages.groovy",)


def find_closure_end(lines: list[str], open_line: int) -> int:
    depth = 0
    started = False
    for i in range(open_line, len(lines)):
        for ch in lines[i]:
            if ch == "{":
                depth += 1
                started = True
            elif ch == "}":
                depth -= 1
        if started and depth == 0:
            return i
    raise ValueError(f"no matching closing brace at line {open_line + 1}")


def find_stage_line_indices(body_lines: list[str]) -> list[int]:
    indices: list[int] = []
    for i, line in enumerate(body_lines):
        if 'stage("Step ' in line and "—" in line:
            indices.append(i)
    if len(indices) != 12:
        raise ValueError(f"expected 12 stage() lines in runPaasDeploy body, found {len(indices)}")
    return indices


def split_helpers(lines: list[str], vars_start: int) -> tuple[str, str, str]:
    helper_lines = lines[:vars_start]
    names = [i for i, ln in enumerate(helper_lines) if ln.startswith("def ")]
    if len(names) < 6:
        raise ValueError("too few helper defs to split")
    h1_end = next(i for i, ln in enumerate(helper_lines) if ln.startswith("def normalizeCosignPrivateKeyPem"))
    h2_end = next(i for i, ln in enumerate(helper_lines) if ln.startswith("def dockerlessImagePush("))
    return (
        "".join(helper_lines[:h1_end]),
        "".join(helper_lines[h1_end:h2_end]),
        "".join(helper_lines[h2_end:]),
    )


def split_stages_parts(body_lines: list[str], vars_block: str) -> dict[str, str]:
    stage_idx = find_stage_line_indices(body_lines)
    bounds = stage_idx + [len(body_lines)]
    groups = [
        ("runPaasDeploySteps1_2", 0, 2),
        ("runPaasDeployStep3", 2, 3),
        ("runPaasDeploySteps4_5", 3, 5),
        ("runPaasDeployStep6", 5, 6),
        ("runPaasDeploySteps7_8", 6, 8),
        ("runPaasDeploySteps9_12", 8, 12),
    ]
    closures: dict[str, str] = {}
    if stage_idx[0] > 0:
        init = "".join(body_lines[0 : stage_idx[0]]).rstrip() + "\n"
        closures["runPaasDeployEnvInit"] = f"def runPaasDeployEnvInit = {{\n{init}}}\n"
    for name, g0, g1 in groups:
        start = bounds[g0]
        end = bounds[g1]
        chunk = "".join(body_lines[start:end]).rstrip() + "\n"
        closures[name] = f"def {name} = {{\n{chunk}}}\n"
    calls = [
        "runPaasDeployEnvInit()",
        "runPaasDeploySteps1_2()",
        "runPaasDeployStep3()",
        "runPaasDeploySteps4_5()",
        "runPaasDeployStep6()",
        "runPaasDeploySteps7_8()",
        "runPaasDeploySteps9_12()",
    ]
    orchestrator = "def runPaasDeploy = {\n" + "\n".join(f"  {c}" for c in calls) + "\n}\n"
    vars_part = vars_block + closures.get("runPaasDeployEnvInit", "")
    p1 = closures["runPaasDeploySteps1_2"] + closures["runPaasDeployStep3"]
    p2 = closures["runPaasDeploySteps4_5"] + closures["runPaasDeployStep6"]
    p3 = closures["runPaasDeploySteps7_8"] + closures["runPaasDeploySteps9_12"] + orchestrator
    combined = vars_part + p1 + p2 + p3
    return {
        "paas-deploy-stages-vars.groovy": vars_part,
        "paas-deploy-stages-p1.groovy": p1,
        "paas-deploy-stages-p2.groovy": p2,
        "paas-deploy-stages-p3.groovy": p3,
        "paas-deploy-stages.groovy": combined,
    }


def header(part: str) -> str:
    return f"// STAGES_BUNDLE_VERSION={BUNDLE_MARKER}\n"


def render_bundle(main_path: Path) -> dict[str, str]:
    text = main_path.read_text(encoding="utf-8").replace("\r\n", "\n")
    lines = text.splitlines(keepends=True)
    vars_start = next(i for i, line in enumerate(lines) if line.startswith("def agentLabel = "))
    body_start = next(i for i, line in enumerate(lines) if line.startswith("def runPaasDeploy = {"))
    end = find_closure_end(lines, body_start)
    h1, h2, h3 = split_helpers(lines, vars_start)
    vars_block = "".join(lines[vars_start:body_start])
    body_lines = lines[body_start + 1 : end]
    stage_parts = split_stages_parts(body_lines, vars_block)
    bundle: dict[str, str] = {
        HELPER_FILES[0]: header("helpers h1") + h1,
        HELPER_FILES[1]: header("helpers h2") + h2,
        HELPER_FILES[2]: header("helpers h3") + h3,
    }
    for name, content in stage_parts.items():
        part_label = name.replace("paas-deploy-stages", "stages").replace(".groovy", "")
        bundle[name] = header(part_label) + content
    return bundle


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--out-dir",
        type=Path,
        help="Write split bundle files to directory (default: stdout = stages file only for compat)",
    )
    parser.add_argument(
        "--stdout-stages-only",
        action="store_true",
        help="Emit only paas-deploy-stages.groovy on stdout (legacy)",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    main_path = root / "Jenkinsfile.paas-deploy"
    if not main_path.is_file():
        print(f"ERROR: missing {main_path}", file=sys.stderr)
        return 1
    split_script = root / "split-cps-hotspots.py"
    if split_script.is_file():
        import subprocess

        subprocess.run([sys.executable, str(split_script)], check=False)
    try:
        bundle = render_bundle(main_path)
    except (StopIteration, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    if args.out_dir:
        args.out_dir.mkdir(parents=True, exist_ok=True)
        for name in LOAD_FILES:
            content = bundle[name]
            out = args.out_dir / name
            out.write_text(content, encoding="utf-8")
            print(f"OK wrote {out} ({len(content)} bytes)", file=sys.stderr)
        return 0
    if args.stdout_stages_only:
        sys.stdout.buffer.write(bundle["paas-deploy-stages.groovy"].encode("utf-8"))
        return 0
    sys.stdout.buffer.write(bundle["paas-deploy-stages.groovy"].encode("utf-8"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
