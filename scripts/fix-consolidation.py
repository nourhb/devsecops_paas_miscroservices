#!/usr/bin/env python3
"""Fix broken merges from consolidate-frontend.py."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "paas" / "frontend" / "src"

IMPORT_LINE = re.compile(r"^import .+\n(?:import .+\n)*", re.M)


def strip_imports(text: str) -> str:
    return IMPORT_LINE.sub("", text, count=1).lstrip("\n")


def extract_section(text: str, marker: str) -> tuple[str, str]:
    idx = text.find(marker)
    if idx < 0:
        return text, ""
    return text[:idx].rstrip() + "\n", text[idx + len(marker) :].lstrip("\n")


def fix_build_backend() -> None:
    path = ROOT / "server/build/build-backend.ts"
    text = path.read_text(encoding="utf-8")
    head, tail = extract_section(text, "// --- build-backend-jenkins ---")
    if not tail:
        return
    jenkins_part, tekton_part = extract_section(tail, "// --- build-backend-tekton ---")
    jenkins_part = strip_imports(jenkins_part)
    tekton_part = strip_imports(tekton_part)
    factory = """
let backend: BuildBackend | null = null;
export function getBuildBackend(): BuildBackend {
    if (backend) {
        return backend;
    }
    backend = resolveBuildProvider() === "tekton" ? new TektonBuildBackend() : new JenkinsBuildBackend();
    return backend;
}
"""
    head = re.sub(
        r"let backend: BuildBackend \| null = null;\nexport function getBuildBackend\(\): BuildBackend \{[\s\S]*?\n\}\n?",
        "",
        head,
    )
    path.write_text(head.rstrip() + "\n\n" + jenkins_part.strip() + "\n\n" + tekton_part.strip() + "\n" + factory, encoding="utf-8")


def fix_auth_service() -> None:
    path = ROOT / "server/auth/auth-service.ts"
    text = path.read_text(encoding="utf-8")
    head, tail = extract_section(text, "// --- auth-tokens ---")
    if not tail:
        return
    tokens_part, rest = extract_section(tail, "// --- session-cookie ---")
    session_part, main = extract_section(rest, "import crypto from")
    if main.startswith('"'):
        main = "import crypto from" + main.split("import crypto from", 1)[-1] if "import crypto from" in rest else main
    # Re-parse: main body is everything before auth-tokens
    main_end = text.find("// --- auth-tokens ---")
    main = text[:main_end].rstrip()
    tokens_part = strip_imports(tokens_part)
    session_part = strip_imports(session_part)
    if 'from "@/server/http/response"' not in main:
        main = main.replace(
            'import { signToken } from "@/server/security/jwt";',
            'import { ApiError, UnauthorizedError, ValidationError } from "@/server/http/response";\nimport { signToken } from "@/server/security/jwt";',
        )
    path.write_text(
        main
        + "\n\n"
        + tokens_part.strip()
        + "\n\n"
        + session_part.strip()
        + "\n\n"
        + text[main_end:].split("// --- auth-tokens ---", 1)[1].split("// --- session-cookie ---", 1)[1].split("\n", 1)[1]
        if False
        else ""
        ,
        encoding="utf-8",
    )


def fix_auth_service_v2() -> None:
    path = ROOT / "server/auth/auth-service.ts"
    text = path.read_text(encoding="utf-8")
    marker = "// --- auth-tokens ---"
    if marker not in text:
        return
    main, appended = text.split(marker, 1)
    tokens_raw, session_raw = appended.split("// --- session-cookie ---", 1)
    tokens_part = strip_imports(tokens_raw)
    session_part = strip_imports(session_raw)
    main = main.rstrip()
    if 'from "@/server/http/response"' not in main:
        main = main.replace(
            'import { signToken } from "@/server/security/jwt";',
            'import { ApiError, UnauthorizedError, ValidationError } from "@/server/http/response";\nimport { signToken } from "@/server/security/jwt";',
        )
    # main already contains service code without appended helpers
    path.write_text(main + "\n\n" + tokens_part.strip() + "\n\n" + session_part.strip() + "\n", encoding="utf-8")


def fix_argocd_service() -> None:
    path = ROOT / "server/services/argocd-service.ts"
    text = path.read_text(encoding="utf-8")
    head, auth = extract_section(text, "// --- argocd auth ---")
    if not auth:
        return
    auth = strip_imports(auth)
    auth = re.sub(r"function getArgoCdApiBase\(\): string \{[\s\S]*?\}\n\n", "", auth)
    if 'from "@/server/http/response"' not in head:
        head = head.replace(
            'import type { ArgoCdStatus } from "@/types";',
            'import { IntegrationError } from "@/server/http/response";\nimport { formatFetchErrorChain } from "@/server/http/integration-fetch";\nimport type { ArgoCdStatus } from "@/types";',
        )
    if 'from "@/server/http/argocd-fetch"' not in head:
        head = head.replace(
            'import { env } from "@/server/config/env";',
            'import { env } from "@/server/config/env";\nimport { argocdIntegrationFetch } from "@/server/http/argocd-fetch";',
        )
    path.write_text(head.rstrip() + "\n\n" + auth.strip() + "\n", encoding="utf-8")


def fix_deployment_service() -> None:
    path = ROOT / "server/services/deployment-service.ts"
    text = path.read_text(encoding="utf-8")
    head, failure = extract_section(text, "// --- deployment failure ---")
    if not failure:
        return
    failure = strip_imports(failure)
    if 'from "@/server/http/response"' not in head:
        head = head.replace(
            'import { resolveAppUrlForClient } from "@/server/deploy/app-public-url";',
            'import { resolveAppUrlForClient } from "@/server/deploy/app-public-url";\nimport { ApiError, IntegrationError, NotFoundError } from "@/server/http/response";',
        )
    if "withPrismaRetry" not in head:
        head = head.replace(
            'import { prisma } from "@/server/db/prisma";',
            'import { prisma } from "@/server/db/prisma";\nimport { withPrismaRetry } from "@/server/db/prisma-retry";',
        )
    if "notifyPipelineFailureEmail" not in head:
        head = head.replace(
            'import { tryCompleteDeploymentIfLive } from "@/server/services/cluster-deploy-service";',
            'import { notifyPipelineFailureEmail } from "@/server/notifications/pipeline-failure-notify";\nimport { tryCompleteDeploymentIfLive } from "@/server/services/cluster-deploy-service";',
        )
    path.write_text(head.rstrip() + "\n\n" + failure.strip() + "\n", encoding="utf-8")


def fix_pipeline_help() -> None:
    path = ROOT / "components/pipeline/pipeline-help.tsx"
    text = path.read_text(encoding="utf-8")
    head, modal = extract_section(text, "// --- help modal ---")
    if not modal:
        return
    modal = modal.replace('"use client";\n', "")
    modal = strip_imports(modal)
    imports = '''"use client";
import * as React from "react";
import Link from "next/link";
import { AlertCircle, CheckCircle2, HelpCircle, Info, Loader2 } from "lucide-react";
import { useQuery } from "@tanstack/react-query";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Dialog, DialogBody, DialogClose, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { Skeleton } from "@/components/ui/skeleton";
import { pipelineApi } from "@/lib/api";
import { useProjectIdFromRoute } from "@/hooks/use-project-id-from-route";
import type { PipelineHelpItem, PipelineHelpSeverity } from "@/types";
import { cn } from "@/lib/utils";

'''
    body = strip_imports(head.replace('"use client";\n', ""))
    path.write_text(imports + body.strip() + "\n\n" + modal.strip() + "\n", encoding="utf-8")


def fix_pipeline_help_service() -> None:
    path = ROOT / "server/help/pipeline-help-service.ts"
    text = path.read_text(encoding="utf-8")
    marker = "// --- help catalog ---"
    if marker not in text:
        return
    service_part, catalog_part = text.split(marker, 1)
    catalog_part = strip_imports(catalog_part)
    imports = '''import type { DeploymentFailureReason } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { parsePipelineVerificationLogs } from "@/server/jenkins/pipeline-step-verification";
import { deploymentFailureStageLabel } from "@/lib/deployment-failure-labels";
import type { PipelineHelpAction, PipelineHelpItem, PipelineHelpResponse, PipelineHelpSeverity } from "@/types";
import { PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES } from "@/lib/paas-deploy-jenkins-stages";
import { getProjectById } from "@/server/projects/project-service";

'''
    service_body = strip_imports(service_part)
    path.write_text(imports + catalog_part.strip() + "\n\n" + service_body.strip() + "\n", encoding="utf-8")


def fix_gitops_blue_green() -> None:
    path = ROOT / "server/gitops/gitops-blue-green.ts"
    text = path.read_text(encoding="utf-8")
    for marker in ("// --- gitops paths ---", "// --- gitops locks ---"):
        if marker in text:
            head, section = text.split(marker, 1)
            next_marker = re.search(r"\n// --- ", section)
            if next_marker:
                body = section[: next_marker.start()]
                rest = section[next_marker.start() + 1 :]
            else:
                body, rest = section, ""
            body = strip_imports(body)
            text = head.rstrip() + "\n\n" + body.strip() + "\n\n" + rest.lstrip("\n")
    path.write_text(text, encoding="utf-8")


def fix_platform_integrations() -> None:
    path = ROOT / "server/platform/platform-integrations.ts"
    text = path.read_text(encoding="utf-8")
    marker = "// --- browser tool URLs ---"
    if marker not in text:
        return
    head, browser = text.split(marker, 1)
    browser = strip_imports(browser)
    browser = browser.replace("function trimUrl(", "function trimBrowserUrl(")
    browser = browser.replace("trimUrl(value)", "trimBrowserUrl(value)")
    browser = browser.replace("trimUrl(candidate)", "trimBrowserUrl(candidate)")
    path.write_text(head.rstrip() + "\n\n" + browser.strip() + "\n", encoding="utf-8")


def fix_integration_fetch() -> None:
    path = ROOT / "server/http/integration-fetch.ts"
    text = path.read_text(encoding="utf-8")
    if 'from "@/server/http/response"' not in text:
        text = text.replace(
            'import { Agent, fetch as undiciFetch } from "undici";',
            'import { ApiError } from "@/server/http/response";\nimport { Agent, fetch as undiciFetch } from "undici";',
        )
        path.write_text(text, encoding="utf-8")


def main() -> None:
    fix_build_backend()
    fix_auth_service_v2()
    fix_argocd_service()
    fix_deployment_service()
    fix_pipeline_help()
    fix_pipeline_help_service()
    fix_gitops_blue_green()
    fix_platform_integrations()
    fix_integration_fetch()
    print("Merge fixes applied.")


if __name__ == "__main__":
    main()
