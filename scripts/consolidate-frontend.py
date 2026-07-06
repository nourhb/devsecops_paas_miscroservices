#!/usr/bin/env python3
"""Merge small frontend modules and rewrite imports."""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "paas" / "frontend" / "src"

IMPORT_REPLACEMENTS: dict[str, str] = {
    '@/server/http/errors': '@/server/http/response',
    '@/server/http/format-fetch-error': '@/server/http/integration-fetch',
    '@/server/http/ttl-cache': '@/server/http/integration-fetch',
    '@/server/http/rate-limit': '@/server/http/integration-fetch',
    '@/server/platform/platform-browser-url': '@/server/platform/platform-integrations',
    '@/server/gitops/gitops-paths': '@/server/gitops/gitops-blue-green',
    '@/server/gitops/gitops-commit-lock': '@/server/gitops/gitops-blue-green',
    '@/server/services/argocd-auth': '@/server/services/argocd-service',
    '@/server/services/deployment-failure': '@/server/services/deployment-service',
    '@/server/help/pipeline-help-catalog': '@/server/help/pipeline-help-service',
    '@/server/jenkins/jenkins-result-user-message': '@/server/jenkins/pipeline-step-verification',
    '@/server/jenkins/jenkins-build-artifact': '@/server/jenkins/pipeline-step-verification',
    '@/lib/app-reachability': '@/lib/resolve-project-id-from-path',
    '@/server/config/real-values': '@/server/config/env',
    '@/server/auth/auth-tokens': '@/server/auth/auth-service',
    '@/server/auth/session-cookie': '@/server/auth/auth-service',
    '@/components/pipeline/pipeline-help-modal': '@/components/pipeline/pipeline-help',
    '@/server/build/build-backend-jenkins': '@/server/build/build-backend',
    '@/server/build/build-backend-tekton': '@/server/build/build-backend',
}

DELETE_FILES = [
    "server/http/errors.ts",
    "server/http/format-fetch-error.ts",
    "server/http/ttl-cache.ts",
    "server/http/rate-limit.ts",
    "server/platform/platform-browser-url.ts",
    "server/gitops/gitops-paths.ts",
    "server/gitops/gitops-commit-lock.ts",
    "server/services/argocd-auth.ts",
    "server/services/deployment-failure.ts",
    "server/help/pipeline-help-catalog.ts",
    "server/jenkins/jenkins-result-user-message.ts",
    "server/jenkins/jenkins-build-artifact.ts",
    "lib/app-reachability.ts",
    "server/config/real-values.ts",
    "server/auth/auth-tokens.ts",
    "server/auth/session-cookie.ts",
    "components/pipeline/pipeline-help-modal.tsx",
    "server/build/build-backend-jenkins.ts",
    "server/build/build-backend-tekton.ts",
]

HEADER_PATTERNS = [
    re.compile(r"^// Server logic for .+\n", re.M),
    re.compile(r"^// Shared frontend helper for .+\n", re.M),
    re.compile(r"^// React (hook|component) for .+\n", re.M),
    re.compile(r'^"use client";\n// React .+\n', re.M),
]


def strip_auto_header(text: str) -> str:
    for pat in HEADER_PATTERNS:
        text = pat.sub("", text, count=1)
    return text


def read_body(path: Path) -> str:
    return strip_auto_header(path.read_text(encoding="utf-8"))


def append_to_file(target: Path, section: str, body: str) -> None:
    content = target.read_text(encoding="utf-8")
    content = strip_auto_header(content)
    if section not in content:
        content = content.rstrip() + f"\n\n// --- {section} ---\n" + body.strip() + "\n"
        target.write_text(content, encoding="utf-8")


def prepend_to_file(target: Path, body: str) -> None:
    content = target.read_text(encoding="utf-8")
    content = strip_auto_header(content)
    # Keep "use client" at top for tsx
    use_client = ""
    if content.startswith('"use client";'):
        use_client = '"use client";\n'
        content = content[len('"use client";') :].lstrip("\n")
    target.write_text(use_client + body.strip() + "\n\n" + content, encoding="utf-8")


def rewrite_imports() -> None:
    for path in list(ROOT.rglob("*.ts")) + list(ROOT.rglob("*.tsx")):
        text = path.read_text(encoding="utf-8")
        original = text
        for old, new in IMPORT_REPLACEMENTS.items():
            text = text.replace(f'from "{old}"', f'from "{new}"')
            text = text.replace(f"from '{old}'", f"from '{new}'")
        if text != original:
            path.write_text(text, encoding="utf-8")


def strip_all_headers() -> None:
    for path in list(ROOT.rglob("*.ts")) + list(ROOT.rglob("*.tsx")):
        text = path.read_text(encoding="utf-8")
        cleaned = strip_auto_header(text)
        if cleaned != text:
            path.write_text(cleaned, encoding="utf-8")


def merge_errors_into_response() -> None:
    target = ROOT / "server/http/response.ts"
    body = read_body(ROOT / "server/http/errors.ts")
    prepend_to_file(target, body)
    content = target.read_text(encoding="utf-8")
    content = content.replace('import { ApiError } from "@/server/http/errors";\n', "")
    target.write_text(content, encoding="utf-8")


def merge_http_helpers() -> None:
    target = ROOT / "server/http/integration-fetch.ts"
    for name in ("format-fetch-error", "ttl-cache", "rate-limit"):
        body = read_body(ROOT / f"server/http/{name}.ts")
        body = body.replace('import { ApiError } from "@/server/http/errors";', "")
        append_to_file(target, name, body)


def merge_platform_browser_url() -> None:
    target = ROOT / "server/platform/platform-integrations.ts"
    body = read_body(ROOT / "server/platform/platform-browser-url.ts")
    body = body.replace('import { realValueOrEmpty } from "@/server/config/real-values";', "")
    append_to_file(target, "browser tool URLs", body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { browserToolHref } from "@/server/platform/platform-browser-url";\n', ""
    )
    target.write_text(content, encoding="utf-8")


def merge_gitops_helpers() -> None:
    target = ROOT / "server/gitops/gitops-blue-green.ts"
    for name, section in (("gitops-paths", "gitops paths"), ("gitops-commit-lock", "gitops locks")):
        body = read_body(ROOT / f"server/gitops/{name}.ts")
        body = body.replace(
            'import { gitopsChartShortNameForProject } from "@/server/gitops/gitops-paths";\n', ""
        )
        append_to_file(target, section, body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { gitopsChartShortNameForProject } from "@/server/gitops/gitops-paths";\n', ""
    )
    target.write_text(content, encoding="utf-8")


def merge_argocd_auth() -> None:
    target = ROOT / "server/services/argocd-service.ts"
    body = read_body(ROOT / "server/services/argocd-auth.ts")
    append_to_file(target, "argocd auth", body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { argocdFetchWithAuth, resolveArgoCdAuthHeader } from "@/server/services/argocd-auth";\n', ""
    )
    content = content.replace(
        'import { formatFetchErrorChain } from "@/server/http/format-fetch-error";\n', ""
    )
    content = content.replace('import { IntegrationError } from "@/server/http/errors";', "")
    target.write_text(content, encoding="utf-8")


def merge_deployment_failure() -> None:
    target = ROOT / "server/services/deployment-service.ts"
    body = read_body(ROOT / "server/services/deployment-failure.ts")
    append_to_file(target, "deployment failure", body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";\n',
        "",
    )
    content = content.replace('import { ApiError, IntegrationError, NotFoundError } from "@/server/http/errors";', "")
    target.write_text(content, encoding="utf-8")


def merge_help_catalog() -> None:
    target = ROOT / "server/help/pipeline-help-service.ts"
    content = target.read_text(encoding="utf-8")
    content = re.sub(
        r"import \{[\s\S]*?\} from \"@/server/help/pipeline-help-catalog\";\n",
        "",
        content,
        count=1,
    )
    target.write_text(content, encoding="utf-8")
    body = read_body(ROOT / "server/help/pipeline-help-catalog.ts")
    append_to_file(target, "help catalog", body)


def merge_jenkins_helpers() -> None:
    target = ROOT / "server/jenkins/pipeline-step-verification.ts"
    for name in ("jenkins-result-user-message", "jenkins-build-artifact"):
        body = read_body(ROOT / f"server/jenkins/{name}.ts")
        append_to_file(target, name, body)


def merge_app_reachability() -> None:
    target = ROOT / "lib/resolve-project-id-from-path.ts"
    body = read_body(ROOT / "lib/app-reachability.ts")
    append_to_file(target, "app reachability", body)


def merge_real_values() -> None:
    target = ROOT / "server/config/env.ts"
    body = read_body(ROOT / "server/config/real-values.ts")
    append_to_file(target, "real values", body)


def merge_auth_helpers() -> None:
    target = ROOT / "server/auth/auth-service.ts"
    for name in ("auth-tokens", "session-cookie"):
        body = read_body(ROOT / f"server/auth/{name}.ts")
        if name == "session-cookie":
            body = body.replace('import { env } from "@/server/config/env";\n', "")
        append_to_file(target, name, body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { createRawAuthToken, hashAuthToken } from "@/server/auth/auth-tokens";\n', ""
    )
    content = content.replace('import { ApiError, UnauthorizedError, ValidationError } from "@/server/http/errors";', "")
    target.write_text(content, encoding="utf-8")


def merge_pipeline_help_modal() -> None:
    target = ROOT / "components/pipeline/pipeline-help.tsx"
    body = read_body(ROOT / "components/pipeline/pipeline-help-modal.tsx")
    append_to_file(target, "help modal", body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { PipelineHelpModal } from "@/components/pipeline/pipeline-help-modal";\n', ""
    )
    target.write_text(content, encoding="utf-8")


def merge_build_backends() -> None:
    target = ROOT / "server/build/build-backend.ts"
    for name in ("build-backend-jenkins", "build-backend-tekton"):
        body = read_body(ROOT / f"server/build/{name}.ts")
        append_to_file(target, name, body)
    content = target.read_text(encoding="utf-8")
    content = content.replace(
        'import { JenkinsBuildBackend } from "@/server/build/build-backend-jenkins";\n', ""
    )
    content = content.replace(
        'import { TektonBuildBackend } from "@/server/build/build-backend-tekton";\n', ""
    )
    target.write_text(content, encoding="utf-8")


def delete_merged_files() -> None:
    for rel in DELETE_FILES:
        path = ROOT / rel
        if path.exists():
            path.unlink()


def main() -> None:
    merge_errors_into_response()
    merge_http_helpers()
    merge_platform_browser_url()
    merge_gitops_helpers()
    merge_argocd_auth()
    merge_deployment_failure()
    merge_help_catalog()
    merge_jenkins_helpers()
    merge_app_reachability()
    merge_real_values()
    merge_auth_helpers()
    merge_pipeline_help_modal()
    merge_build_backends()
    rewrite_imports()
    delete_merged_files()
    strip_all_headers()
    print("Consolidation complete.")


if __name__ == "__main__":
    main()
