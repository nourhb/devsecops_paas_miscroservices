import type { JenkinsPipelineStageRow } from "@/lib/api";
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
};
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
        return labels.map((name) => ({
            name,
            status: "SUCCESS",
            durationMs: null,
            synthetic: true
        }));
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
export function buildPaasDeployDisplayStages(live: JenkinsPipelineStageRow[], wf: WfMeta | undefined): PaasDeployDisplayStage[] {
    if (!wf?.configured || wf.skipped) {
        return PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((name) => ({
            name,
            status: "NOT_EXECUTED",
            durationMs: null,
            synthetic: true
        }));
    }
    if (live.length > 0) {
        return mergeReferenceWithLiveStages(live);
    }
    if (wf.error) {
        return syntheticStagesWhenWfapiUnavailable(wf);
    }
    return PAAS_DEPLOY_INCREMENTAL_JENKINS_STAGES.map((name) => ({
        name,
        status: "NOT_EXECUTED",
        durationMs: null,
        synthetic: true
    }));
}
