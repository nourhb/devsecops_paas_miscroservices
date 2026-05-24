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
