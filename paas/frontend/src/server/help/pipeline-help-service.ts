import type { DeploymentFailureReason } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { parsePipelineVerificationLogs } from "@/server/jenkins/pipeline-step-verification";
import {
    buildHelpFromDeployCheck,
    buildHelpFromFailure,
    buildHelpFromJenkinsCheck,
    buildHelpFromRawLogs,
    buildNoLogsHelpItem,
    buildSuccessHelpItem
} from "@/server/help/pipeline-help-catalog";
import type { PipelineHelpItem, PipelineHelpResponse, PipelineHelpSeverity } from "@/types";
import { getProjectById } from "@/server/projects/project-service";

function worstSeverity(items: PipelineHelpItem[]): PipelineHelpSeverity {
    if (items.some((i) => i.severity === "error")) {
        return "error";
    }
    if (items.some((i) => i.severity === "warning")) {
        return "warning";
    }
    if (items.some((i) => i.severity === "success")) {
        return "success";
    }
    return "info";
}

function dedupeItems(items: PipelineHelpItem[]): PipelineHelpItem[] {
    const seen = new Set<string>();
    const out: PipelineHelpItem[] = [];
    for (const item of items) {
        if (seen.has(item.id)) {
            continue;
        }
        seen.add(item.id);
        out.push(item);
    }
    return out.slice(0, 8);
}

function sortItems(items: PipelineHelpItem[]): PipelineHelpItem[] {
    const rank: Record<PipelineHelpSeverity, number> = {
        error: 0,
        warning: 1,
        info: 2,
        success: 3
    };
    return [...items].sort((a, b) => rank[a.severity] - rank[b.severity]);
}

function buildSummary(overall: PipelineHelpSeverity, items: PipelineHelpItem[]): { summary: string; headline: string } {
    const errors = items.filter((i) => i.severity === "error").length;
    const warnings = items.filter((i) => i.severity === "warning").length;
    if (overall === "error") {
        return {
            headline: "Something needs your attention",
            summary: errors === 1
                ? "We found 1 issue that may be blocking your pipeline."
                : `We found ${errors} issues that may be blocking your pipeline.`
        };
    }
    if (overall === "warning") {
        return {
            headline: "Build finished, with a few warnings",
            summary: warnings === 1
                ? "Your app may still work, but 1 item is worth fixing when you can."
                : `Your app may still work, but ${warnings} items are worth fixing when you can.`
        };
    }
    if (overall === "success") {
        return {
            headline: "You're all set",
            summary: "The last run looks healthy. No fixes required right now."
        };
    }
    return {
        headline: "Pipeline help",
        summary: "Here is what we understood from your last build log."
    };
}

async function resolveLogs(projectId: string, projectName: string): Promise<{
    logs: string;
    deploymentId: string | null;
    jenkinsBuildNumber: number | null;
    failureReason: DeploymentFailureReason | null;
    failureMessage: string | null;
    deploymentFailed: boolean;
}> {
    const recent = await prisma.deployment.findFirst({
        where: { projectId },
        orderBy: { createdAt: "desc" },
        select: {
            id: true,
            logs: true,
            jenkinsBuildNumber: true,
            failureReason: true,
            failureMessage: true,
            status: true
        }
    });
    let logs = recent?.logs ?? "";
    const buildNum = recent?.jenkinsBuildNumber ?? null;
    const needsJenkins = buildNum != null && !/PAAS_STEP_(OK|WARN|FAIL|SKIP)/i.test(logs);
    if (needsJenkins) {
        try {
            const console = await jenkinsClient.getBuildConsoleText(projectName, projectId, buildNum, "deploy");
            if (console?.trim()) {
                logs = console.length <= DEPLOYMENT_LOG_TAIL_MAX_CHARS
                    ? console
                    : console.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
            }
        }
        catch {
            // keep stored logs
        }
    }
    const deploymentFailed = recent?.status === "FAILED";
    return {
        logs,
        deploymentId: recent?.id ?? null,
        jenkinsBuildNumber: buildNum,
        failureReason: recent?.failureReason ?? null,
        failureMessage: recent?.failureMessage ?? null,
        deploymentFailed
    };
}

export async function getPipelineHelp(projectId: string): Promise<PipelineHelpResponse> {
    const project = await getProjectById(projectId);
    const bundle = await resolveLogs(projectId, project.projectName);
    const hasLogs = Boolean(bundle.logs.trim());
    if (!hasLogs) {
        const items = [buildNoLogsHelpItem()];
        const overall = "info";
        const { summary, headline } = buildSummary(overall, items);
        return {
            projectId,
            deploymentId: bundle.deploymentId,
            jenkinsBuildNumber: bundle.jenkinsBuildNumber,
            overall,
            summary,
            headline,
            items,
            hasLogs: false
        };
    }
    const parsed = parsePipelineVerificationLogs(bundle.logs);
    const items: PipelineHelpItem[] = [];
    for (const check of parsed.jenkinsChecks) {
        const item = buildHelpFromJenkinsCheck(check);
        if (item) {
            items.push(item);
        }
    }
    for (const check of parsed.deployChecks) {
        const item = buildHelpFromDeployCheck(check);
        if (item) {
            items.push(item);
        }
    }
    if (bundle.deploymentFailed) {
        items.unshift(buildHelpFromFailure(bundle.failureReason, bundle.failureMessage));
    }
    const buildFailed = parsed.buildComplete?.result?.toUpperCase() === "FAILURE"
        || parsed.buildComplete?.result?.toUpperCase() === "ABORTED";
    if (buildFailed && items.every((i) => i.severity !== "error")) {
        items.unshift({
            id: "jenkins-build-failed",
            severity: "error",
            stepLabel: "Build",
            happened: "The Jenkins build did not succeed.",
            means: parsed.buildComplete?.result
                ? `Build result: ${parsed.buildComplete.result}.`
                : "The controller reported a failed or aborted build.",
            fix: "Open the Jenkins console, find the first error (often in red), fix it, push your code, and rebuild."
        });
    }
    if (items.length === 0) {
        const rawHints = buildHelpFromRawLogs(bundle.logs);
        if (rawHints.length > 0) {
            items.push(...rawHints);
        }
        else {
            items.push(buildSuccessHelpItem());
        }
    }
    else if (items.every((i) => i.severity === "info" || i.severity === "warning")) {
        const rawHints = buildHelpFromRawLogs(bundle.logs).filter((h) => h.severity === "error");
        items.push(...rawHints);
    }
    const deduped = dedupeItems(sortItems(items));
    const overall = worstSeverity(deduped);
    const { summary, headline } = buildSummary(overall, deduped);
    return {
        projectId,
        deploymentId: bundle.deploymentId,
        jenkinsBuildNumber: bundle.jenkinsBuildNumber,
        overall,
        summary,
        headline,
        items: deduped,
        hasLogs: true
    };
}
