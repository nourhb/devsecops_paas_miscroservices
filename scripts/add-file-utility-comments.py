#!/usr/bin/env python3
# Python helper for add file utility comments
"""Add an ~8-word utility comment at the top of project source files."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

SKIP = {
    "paas/frontend/src/server/jenkins/embedded-jenkinsfile.ts",
    "paas/frontend/package-lock.json",
    "paas/frontend/next-env.d.ts",
}

SKIP_SUFFIX = {".pdf", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".lock"}

INCLUDE_SUFFIX = {
    ".ts", ".tsx", ".sh", ".py", ".mjs", ".cjs", ".yml", ".yaml",
    ".prisma", ".groovy", ".tpl", ".md", ".bash",
}

OVERRIDES: dict[str, str] = {
    ".gitattributes": "Forces LF line endings on shell scripts for Linux.",
    ".github/workflows/paas-hosting.yml": "CI builds and deploys PaaS frontend on main.",
    "scripts/install-githooks.sh": "Points git at repo hooks for clean commits.",
    "paas/scripts/lab.sh": "Main VM lab operator command dispatcher entrypoint.",
    "paas/scripts/dev.sh": "Starts local Next.js frontend development server only.",
    "paas/scripts/heal-project-deploy-lab.sh": "Heals one project GitOps deploy on lab VM.",
    "paas/README.md": "Overview of PaaS layout, lab commands, and architecture.",
    "paas/frontend/scripts/embed-jenkinsfile.mjs": "Build step embeds Jenkinsfile into TypeScript bundle.",
    "paas/frontend/scripts/flatten-env-for-compose.mjs": "Flattens env files for docker compose deployment.",
    "paas/frontend/scripts/seed-admin-user.cjs": "CLI seeds default admin user into Postgres database.",
    "paas/frontend/scripts/reset-user-password.cjs": "CLI resets a user password in Postgres database.",
    "paas/frontend/scripts/verify-user-email.cjs": "CLI marks user email verified in Postgres database.",
    "paas/jenkins/Jenkinsfile.paas-deploy": "Full twelve step DevSecOps deploy pipeline for Jenkins.",
    "paas/jenkins/Jenkinsfile.paas-deploy-stages.groovy": "Shared Groovy stages loaded by paas deploy job.",
    "paas/jenkins/render-loadable-stages.py": "Splits Jenkins stages into CPS loadable Groovy files.",
    "paas/jenkins/split-cps-hotspots.py": "Splits oversized Groovy hotspots for Jenkins CPS limits.",
    "paas/frontend/prisma/schema.prisma": "Prisma schema for users, projects, and deploy records.",
}

UTILITY_PREFIX = re.compile(
    r"^(?:(?:#|//)\s*.+\n|/\*\s*.+\s\*/\n|'use client';\n|\"use client\";\n|#!/[^\n]+\n)+",
    re.MULTILINE,
)

EXISTING = re.compile(r"^(#|//)\s*.+\n")


def rel(p: Path) -> str:
    return p.relative_to(ROOT).as_posix()


def word_count(s: str) -> int:
    return len(s.split())


def trim_to_eight_words(text: str) -> str:
    words = text.split()
    if len(words) <= 10:
        return text.strip().rstrip(".")
    return " ".join(words[:8]).rstrip(".")


def humanize(name: str) -> str:
    s = re.sub(r"[-_]", " ", name)
    s = re.sub(r"([a-z])([A-Z])", r"\1 \2", s)
    return s.lower()


def describe(path: str) -> str:
    if path in OVERRIDES:
        return OVERRIDES[path]

    p = path.replace("\\", "/")
    name = Path(p).stem
    parent = Path(p).name

    if p.startswith("paas/frontend/src/app/api/") and p.endswith("/route.ts"):
        route = p.removeprefix("paas/frontend/src/app/api/").removesuffix("/route.ts")
        return trim_to_eight_words(f"API route handles {route.replace('/', ' ')} requests")

    if p.startswith("paas/frontend/src/app/") and p.endswith("/page.tsx"):
        area = p.removeprefix("paas/frontend/src/app/").removesuffix("/page.tsx")
        area = area.replace("(", "").replace(")", "").replace("/", " ")
        return trim_to_eight_words(f"Next.js page UI for {area}")

    if p.startswith("paas/frontend/src/app/") and p.endswith("/layout.tsx"):
        area = p.removeprefix("paas/frontend/src/app/").removesuffix("/layout.tsx")
        return trim_to_eight_words(f"Layout wrapper for {area.replace('/', ' ')} pages")

    if p.startswith("paas/frontend/src/app/") and p.endswith("/error.tsx"):
        return trim_to_eight_words("Error boundary UI for dashboard route segment")

    if p.startswith("paas/frontend/src/server/"):
        part = p.removeprefix("paas/frontend/src/server/").rsplit(".", 1)[0]
        part = part.replace("/", " ").replace("-", " ")
        return trim_to_eight_words(f"Server logic for {part}")

    if p.startswith("paas/frontend/src/lib/"):
        part = p.removeprefix("paas/frontend/src/lib/").rsplit(".", 1)[0]
        part = part.replace("/", " ").replace("-", " ")
        return trim_to_eight_words(f"Shared frontend helper for {part}")

    if p.startswith("paas/frontend/src/components/"):
        part = p.removeprefix("paas/frontend/src/components/").rsplit(".", 1)[0]
        part = part.replace("/", " ").replace("-", " ")
        return trim_to_eight_words(f"React component for {part}")

    if p.startswith("paas/frontend/src/types/"):
        return trim_to_eight_words("Shared TypeScript types for frontend API models")

    if p.startswith("paas/frontend/src/hooks/"):
        return trim_to_eight_words(f"React hook for {humanize(name)}")

    if p.endswith("tailwind.config.ts"):
        return trim_to_eight_words("Tailwind CSS theme and design token configuration")

    if p.endswith("next.config.mjs"):
        return trim_to_eight_words("Next.js build and runtime configuration settings")

    if p.startswith("paas/scripts/lib/lab-"):
        action = name.removeprefix("lab-").replace("-", " ")
        return trim_to_eight_words(f"Lab script to {action} on VM cluster")

    if p.startswith("paas/scripts/lib/"):
        action = humanize(name)
        return trim_to_eight_words(f"Lab helper script for {action}")

    if p.startswith("paas/scripts/"):
        return trim_to_eight_words(f"PaaS shell script for {humanize(name)}")

    if p.startswith("paas/gitops/"):
        fname = Path(p).name
        if fname == "Chart.yaml":
            return "Helm chart metadata for GitOps application deploy"
        if fname == "values.yaml":
            return "Default Helm values for GitOps application deploy"
        if fname.startswith("_"):
            return "Helm template helper definitions for chart rendering"
        if "deployment" in fname:
            return "Helm deployment template for GitOps app rollout"
        if "service" in fname:
            return "Helm service template exposing GitOps app pods"
        if "ingress" in fname:
            return "Helm ingress template routing traffic to app"
        return trim_to_eight_words(f"Helm template file for {humanize(fname)}")

    if p.startswith("paas/k8s-manifests/"):
        return trim_to_eight_words(f"Kubernetes manifest for lab or hosted deploy")

    if p.startswith("paas/jenkins/") and p.endswith(".py"):
        return trim_to_eight_words(f"Jenkins pipeline helper script {humanize(name)}")

    if p.startswith(".githooks/"):
        return trim_to_eight_words(f"Git hook script for {humanize(name)}")

    if p.endswith(".sh"):
        return trim_to_eight_words(f"Shell script for {humanize(name)}")

    if p.endswith(".py"):
        return trim_to_eight_words(f"Python helper for {humanize(name)}")

    if p.endswith(".md"):
        return trim_to_eight_words(f"Documentation for {humanize(name)}")

    return trim_to_eight_words(f"Project file for {humanize(name)}")


def comment_line(text: str, suffix: str) -> str:
    if suffix == ".md":
        return f"<!-- {text} -->\n"
    if suffix in {".sh", ".bash", ".yml", ".yaml", ".tpl"}:
        return f"# {text}\n"
    if suffix == ".py" and not text.startswith("#"):
        return f"# {text}\n"
    return f"// {text}\n"


def strip_existing_utility(content: str, suffix: str) -> str:
    lines = content.splitlines(keepends=True)
    if not lines:
        return content

    idx = 0
    if lines[0].startswith("#!"):
        idx = 1

    if idx < len(lines) and lines[idx].strip() in {"'use client';", '"use client";'}:
        idx += 1

    if idx < len(lines):
        first = lines[idx].strip()
        if suffix == ".md" and first.startswith("<!--") and first.endswith("-->"):
            return "".join(lines[:idx] + lines[idx + 1 :])
        if first.startswith("# ") or first.startswith("// "):
            return "".join(lines[:idx] + lines[idx + 1 :])

    return content


def insert_comment(content: str, line: str, suffix: str) -> str:
    content = strip_existing_utility(content, suffix)
    if not content:
        return line

    if content.startswith("#!"):
        nl = content.find("\n")
        if nl == -1:
            return content + line
        return content[: nl + 1] + line + content[nl + 1 :]

    if content.startswith("'use client';") or content.startswith('"use client";'):
        nl = content.find("\n")
        return content[: nl + 1] + line + content[nl + 1 :]

    return line + content


def iter_files() -> list[Path]:
    out: list[Path] = []
    for p in ROOT.rglob("*"):
        if not p.is_file():
            continue
        r = rel(p)
        if r in SKIP or p.suffix in SKIP_SUFFIX:
            continue
        if p.suffix not in INCLUDE_SUFFIX and r not in OVERRIDES:
            continue
        if "node_modules" in p.parts or ".git" in p.parts:
            continue
        out.append(p)
    for name in (".gitattributes",):
        p = ROOT / name
        if p.is_file() and p not in out:
            out.append(p)
    return sorted(out)


def main() -> None:
    changed = 0
    for path in iter_files():
        r = rel(path)
        text = describe(r)
        if word_count(text) > 12:
            text = trim_to_eight_words(text)
        line = comment_line(text, path.suffix if r not in OVERRIDES else Path(r).suffix or path.suffix)
        raw = path.read_text(encoding="utf-8", errors="replace")
        new = insert_comment(raw, line, path.suffix)
        if new != raw:
            path.write_text(new, encoding="utf-8", newline="\n")
            changed += 1
    print(f"OK: updated {changed} files")


if __name__ == "__main__":
    main()
