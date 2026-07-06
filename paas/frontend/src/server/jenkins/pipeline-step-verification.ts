import { buildDeployImageRepositoryForClusterPull, deployImageRepositoryMatchesProject, harborClusterPullImageRef } from "@/server/deploy/deploy-image";

export type PipelineStepCheckLevel = "OK" | "WARN" | "SKIP" | "FAIL";
export interface PipelineStepCheck {
    step: number;
    level: PipelineStepCheckLevel;
    id: string;
    message: string;
}
const STEP_LINE = /PAAS_STEP_(OK|WARN|SKIP|FAIL)\s+step=(\d+)\s+(?:id=(\S+)\s+)?(?:msg|reason)=([^\n\r]+)/gi;
const DEPLOY_LINE = /PAAS_DEPLOY_VERIFY\s+step=(\S+)\s+status=(OK|WARN|FAIL)\s+detail=([^\n\r]+)/gi;
const BUILD_COMPLETE = /PAAS_BUILD_COMPLETE\s+result=(\S+)\s+image=(\S+)\s+project=(\S+)\s+build=(\S+)/i;
export interface ParsedPipelineVerification {
    jenkinsChecks: PipelineStepCheck[];
    deployChecks: Array<{
        step: string;
        status: "OK" | "WARN" | "FAIL";
        detail: string;
    }>;
    buildComplete: {
        result: string;
        image: string;
        project: string;
        build: string;
    } | null;
    artifactImage: string | null;
}
export function parsePipelineVerificationLogs(logText: string): ParsedPipelineVerification {
    const jenkinsChecks: PipelineStepCheck[] = [];
    const deployChecks: ParsedPipelineVerification["deployChecks"] = [];
    let buildComplete: ParsedPipelineVerification["buildComplete"] = null;
    let artifactImage: string | null = null;
    const text = logText ?? "";
    for (const m of text.matchAll(STEP_LINE)) {
        jenkinsChecks.push({
            level: m[1].toUpperCase() as PipelineStepCheckLevel,
            step: Number.parseInt(m[2], 10),
            id: (m[3] ?? "").trim() || "check",
            message: (m[4] ?? "").trim()
        });
    }
    for (const m of text.matchAll(DEPLOY_LINE)) {
        deployChecks.push({
            step: m[1],
            status: m[2].toUpperCase() as "OK" | "WARN" | "FAIL",
            detail: (m[3] ?? "").trim()
        });
    }
    const complete = BUILD_COMPLETE.exec(text);
    if (complete) {
        buildComplete = {
            result: complete[1],
            image: complete[2],
            project: complete[3],
            build: complete[4]
        };
        artifactImage = complete[2];
    }
    const artifactMatches = [...text.matchAll(/PAAS_ARTIFACT_IMAGE=([^\s]+)/g)];
    if (artifactMatches.length > 0) {
        artifactImage = artifactMatches.at(-1)?.[1]?.trim() ?? artifactImage;
    }
    return { jenkinsChecks, deployChecks, buildComplete, artifactImage };
}
export function checksForStep(checks: PipelineStepCheck[], stepNum: number): PipelineStepCheck[] {
    return checks.filter((c) => c.step === stepNum);
}
export function stepHasOk(checks: PipelineStepCheck[], stepNum: number): boolean {
    const row = checksForStep(checks, stepNum);
    if (row.length === 0) {
        return false;
    }
    return row.some((c) => c.level === "OK") && !row.some((c) => c.level === "FAIL");
}
export function mergeJenkinsChecksByStep(...sources: Array<PipelineStepCheck[] | undefined>): PipelineStepCheck[] {
    const byStep = new Map<number, PipelineStepCheck>();
    for (const list of sources) {
        for (const check of list ?? []) {
            byStep.set(check.step, check);
        }
    }
    return [...byStep.entries()].sort((a, b) => a[0] - b[0]).map(([, check]) => check);
}

export function jenkinsResultUserMessage(result: string | null | undefined, logTail: string): string {
    if (result === "ABORTED") {
        return "Jenkins pipeline was cancelled or aborted.";
    }
    const r = result ?? "UNKNOWN";
    const base = `Build backend finished with result: ${r}`;
    if ((result === "FAILURE" || result === "UNSTABLE") && /exit code -2|process apparently never started/i.test(logTail)) {
        return `${base}. Jenkins lost contact with a long shell step (durable-task exit -2), often during dockerless crane pushes; classic Status is authoritative if Blue Ocean still shows green. Retry after updating the Jenkinsfile or check registry/network and JENKINS_CRANE_PUSH_TIMEOUT_MIN.`;
    }
    return base;
}

export function pickJenkinsLogForArtifactVerify(progressiveTail: string, fullConsole: string | null | undefined): string {
    if (/PAAS_BUILD_COMPLETE\s+result=/i.test(progressiveTail)) {
        return progressiveTail;
    }
    const full = fullConsole?.trim();
    if (full) {
        return full;
    }
    return progressiveTail;
}

export function resolveVerifiedArtifactImage(log: string, projectId: string, projectName: string, buildNum: number): {
    image: string | null;
    error: string | null;
} {
    const expectedRepo = buildDeployImageRepositoryForClusterPull(projectName);
    const completeMatches = [...log.matchAll(/PAAS_BUILD_COMPLETE\s+result=(\S+)\s+image=(\S+)\s+project=(\S+)\s+build=(\S+)/gi)];
    const complete = completeMatches.at(-1);
    if (complete) {
        const [, result, image, proj, build] = complete;
        if (proj.trim() !== projectId.trim()) {
            return {
                image: null,
                error: `Jenkins build #${build} belongs to project ${proj}, not this project (${projectId.slice(0, 8)}…). Another deploy may have reused the shared job run number.`
            };
        }
        if (String(result).toUpperCase() !== "SUCCESS") {
            return {
                image: null,
                error: `Jenkins build #${buildNum} finished with result=${result}.`
            };
        }
        const normalized = image.trim().toLowerCase();
        if (!deployImageRepositoryMatchesProject(normalized, projectName)) {
            return {
                image: null,
                error: `Jenkins artifact ${image} does not match expected repository ${expectedRepo} (nip.io push vs IP pull is OK when path is /paas/${projectName.toLowerCase().replace(/[^a-z0-9._-]/g, "-")}).`
            };
        }
        return { image: harborClusterPullImageRef(image.trim()), error: null };
    }
    const artifactMatches = [...log.matchAll(/PAAS_ARTIFACT_IMAGE=([^\s]+)/g)];
    for (let i = artifactMatches.length - 1; i >= 0; i--) {
        const candidate = artifactMatches[i][1]?.trim() ?? "";
        const normalized = candidate.toLowerCase();
        if (deployImageRepositoryMatchesProject(normalized, projectName)) {
            return { image: harborClusterPullImageRef(candidate), error: null };
        }
    }
    return {
        image: null,
        error: `No PAAS_BUILD_COMPLETE or PAAS_ARTIFACT_IMAGE for this project in Jenkins build #${buildNum} console. If Jenkins finished SUCCESS, redeploy the PaaS frontend (log tail fix) or open the Jenkins console and search PAAS_BUILD_COMPLETE.`
    };
}
