import type { JenkinsPipelineStageRow } from "@/lib/api";
import type { PipelineStepCheck, PipelineStepCheckLevel } from "@/server/jenkins/pipeline-step-verification";
export const PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES = [
    "Step 1 — Params validation",
    "Step 2 — Checkout du code (Git / GitHub)",
    "Step 3 — Construction de l'application",
    "Step 4 — Tests SCA (Dependency-Check, CycloneDX, Dependency-Track)",
    "Step 5 — Tests SAST (SonarQube)",
    "Step 6 — Création de l'image Docker",
    "Step 7 — Packaging du chart Helm",
    "Step 8 — Publication des artefacts (Artifactory)",
    "Step 9 — Signature de l'image (Cosign)",
    "Step 10 — DAST (OWASP ZAP baseline)",
    "Step 11 — Publication charts Helm (OCI → Harbor)",
    "Step 12 — GitOps (Argo CD) & archivage Jenkins"
] as const;
export type PaasDeployDisplayStage = JenkinsPipelineStageRow & {
    synthetic?: boolean;
};
function stepNumberPattern(stepNum: number): RegExp {
    return new RegExp(`\\bStep\\s+${stepNum}\\b`, "i");
}
export function mergeReferenceWithLiveStages(live: JenkinsPipelineStageRow[]): PaasDeployDisplayStage[] {
    return PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((label, idx) => {
        const stepNum = idx + 1;
        const hit = live.find((s) => stepNumberPattern(stepNum).test(s.name));
        if (hit) {
            return {
                ...hit,
                synthetic: false
            };
        }
        if (live.length === PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.length && live[idx]) {
            return {
                ...live[idx],
                synthetic: false
            };
        }
        return {
            name: label,
            status: "NOT_EXECUTED",
            durationMs: null,
            synthetic: true
        };
    });
}
type WfMeta = {
    configured?: boolean;
    skipped?: boolean;
    building?: boolean;
    result?: string | null;
    error?: string | null;
    jenkinsChecks?: PipelineStepCheck[];
};
function checkLevelToStageStatus(level: PipelineStepCheckLevel): string {
    switch (level) {
        case "OK":
            return "SUCCESS";
        case "WARN":
            return "UNSTABLE";
        case "SKIP":
            return "UNSTABLE";
        case "FAIL":
            return "FAILURE";
        default:
            return "NOT_EXECUTED";
    }
}
export function applyJenkinsChecksToDisplayStages(stages: PaasDeployDisplayStage[], checks: PipelineStepCheck[] | undefined): PaasDeployDisplayStage[] {
    if (!checks?.length) {
        return stages;
    }
    return stages.map((stage, idx) => {
        const stepNum = idx + 1;
        const stepChecks = checks.filter((check) => check.step === stepNum);
        if (stepChecks.length === 0) {
            return stage;
        }
        const hasFail = stepChecks.some((check) => check.level === "FAIL");
        const hasOk = stepChecks.some((check) => check.level === "OK");
        const allSkip = stepChecks.every((check) => check.level === "SKIP");
        const worst = hasFail
            ? "FAIL"
            : hasOk
                ? "OK"
            : allSkip && !hasOk
                ? "SKIP"
                : stepChecks.some((check) => check.level === "WARN")
                    ? "WARN"
                    : "WARN";
        return {
            ...stage,
            status: checkLevelToStageStatus(worst),
            synthetic: false
        };
    });
}
export function syntheticStagesWhenWfapiUnavailable(wf: WfMeta): PaasDeployDisplayStage[] {
    const labels = PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES;
    const building = Boolean(wf.building);
    const result = (wf.result || "").toUpperCase();
    if (building) {
        return labels.map((name) => ({
            name,
            status: "NOT_EXECUTED",
            durationMs: null,
            synthetic: true
        }));
    }
    if (result === "SUCCESS") {
        const base = labels.map((name) => ({
            name,
            status: "SUCCESS",
            durationMs: null,
            synthetic: true
        }));
        return applyJenkinsChecksToDisplayStages(base, wf.jenkinsChecks);
    }
    if (result === "FAILURE" || result === "ABORTED" || result === "UNSTABLE") {
        return labels.map((name) => ({
            name,
            status: "NOT_EXECUTED",
            durationMs: null,
            synthetic: true
        }));
    }
    return labels.map((name) => ({
        name,
        status: "NOT_EXECUTED",
        durationMs: null,
        synthetic: true
    }));
}
const POST_DEPLOY_VERIFY_STEPS = new Set(["gitops", "argocd_sync", "argocd_ready", "url", "security_gate"]);
function worstPostDeployStageStatus(deployChecks: Array<{
    step: string;
    status: "OK" | "WARN" | "FAIL";
}>): string {
    const post = deployChecks.filter((check) => POST_DEPLOY_VERIFY_STEPS.has(check.step));
    if (post.length === 0) {
        return "NOT_EXECUTED";
    }
    if (post.some((check) => check.status === "FAIL")) {
        return "FAILURE";
    }
    if (post.some((check) => check.status === "WARN" && (check.step === "url" || check.step === "argocd_ready" || check.step === "gitops"))) {
        return "FAILURE";
    }
    if (post.some((check) => check.status === "WARN")) {
        return "UNSTABLE";
    }
    return "SUCCESS";
}
export function applyDeployChecksToDisplayStages(stages: PaasDeployDisplayStage[], deployChecks: Array<{
    step: string;
    status: "OK" | "WARN" | "FAIL";
    detail: string;
}> | undefined, deploymentStatus?: string): PaasDeployDisplayStage[] {
    if (!deployChecks?.length) {
        return stages;
    }
    let worst = worstPostDeployStageStatus(deployChecks);
    if (deploymentStatus?.toUpperCase() === "FAILED" && worst === "SUCCESS") {
        worst = "FAILURE";
    }
    return stages.map((stage, idx) => {
        if (idx !== PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.length - 1) {
            return stage;
        }
        return {
            ...stage,
            status: worst,
            synthetic: false
        };
    });
}
export function buildPaasDeployDisplayStages(live: JenkinsPipelineStageRow[], wf: WfMeta | undefined, deployChecks?: Array<{
    step: string;
    status: "OK" | "WARN" | "FAIL";
    detail: string;
}>, deploymentStatus?: string): PaasDeployDisplayStage[] {
    let stages: PaasDeployDisplayStage[];
    if (!wf?.configured || wf.skipped) {
        stages = PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((name) => ({
            name,
            status: "NOT_EXECUTED",
            durationMs: null,
            synthetic: true
        }));
    }
    else if (live.length > 0) {
        stages = mergeReferenceWithLiveStages(live);
    }
    else if (wf.error) {
        stages = syntheticStagesWhenWfapiUnavailable(wf);
    }
    else {
        stages = PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((name) => ({
            name,
            status: "NOT_EXECUTED",
            durationMs: null,
            synthetic: true
        }));
    }
    return applyDeployChecksToDisplayStages(applyJenkinsChecksToDisplayStages(stages, wf?.jenkinsChecks), deployChecks, deploymentStatus);
}
