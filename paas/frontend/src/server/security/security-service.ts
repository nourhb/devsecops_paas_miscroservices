import type { SecurityMetrics } from "@/types";
import { env } from "@/server/config/env";
import { getKyvernoPolicyStatus } from "@/server/integrations/kubernetes-client";
import { getProjectById } from "@/server/projects/project-service";
import { cosignClient, dependencyTrackClient, opaClient, sonarQubeClient, trivyClient } from "@/server/integrations/devsecops-clients";
import type { Project } from "@prisma/client";

function score(base: number, penalty: number): number {
    const scored = base - penalty;
    return Math.max(0, Math.min(100, scored));
}

function policyEngineLabel(): "Kyverno" | "OPA" | "Gatekeeper" | "None" {
    switch (env.POLICY_ENGINE) {
        case "kyverno":
            return "Kyverno";
        case "opa":
            return "OPA";
        case "gatekeeper":
            return "Gatekeeper";
        default:
            return "None";
    }
}

function emptySeverity() {
    return { critical: 0, high: 0, medium: 0, low: 0 };
}

function integrationProjectKeys(project: Project): string[] {
    return [...new Set([project.id, project.projectName].filter((k) => k.trim()))];
}

async function resolveSonarQualityGate(project: Project): Promise<{
    status: "PASSED" | "FAILED" | "UNKNOWN";
    matchedKey: string | null;
}> {
    for (const key of integrationProjectKeys(project)) {
        const result = await sonarQubeClient.qualityGate(key);
        if (result.status === "PASSED" || result.status === "FAILED") {
            return { status: result.status, matchedKey: key };
        }
    }
    return { status: "UNKNOWN", matchedKey: null };
}

async function resolveDependencyTrackMetrics(project: Project) {
    for (const key of integrationProjectKeys(project)) {
        const row = await dependencyTrackClient.projectMetrics(key);
        if (row.projectUuid != null) {
            return row;
        }
        const hasFindings = row.metrics.critical + row.metrics.high + row.metrics.medium + row.metrics.low > 0;
        if (hasFindings) {
            return row;
        }
    }
    return dependencyTrackClient.projectMetrics(project.id);
}

function buildIntegrationHints(project: Project, sonarStatus: string, dtProjectUuid: string | null): string {
    const hints: string[] = [];
    if (sonarStatus === "UNKNOWN") {
        hints.push("SonarQube: no analysis for this project yet — run a full Jenkins pipeline with SONAR_TOKEN set (JENKINS_PAAS_FAST_PIPELINE=false).");
    }
    if (!dtProjectUuid && env.DEPENDENCY_TRACK_BASE_URL) {
        hints.push("Dependency-Track: no SBOM project — Step 4 must upload bom.json (needs DEPENDENCY_TRACK_API_KEY on Jenkins).");
    }
    if (env.JENKINS_PAAS_FAST_PIPELINE === "true") {
        hints.push("JENKINS_PAAS_FAST_PIPELINE=true skips Sonar and SCA steps.");
    }
    if (hints.length === 0) {
        return "Security integrations reachable.";
    }
    return hints.join(" ");
}

async function buildSecurityMetrics(project: Project): Promise<SecurityMetrics> {
    const imageTag = project.imageTag || project.projectName;
    const sonar = await resolveSonarQualityGate(project);
    const dependencyTrackProject = await resolveDependencyTrackMetrics(project);
    const dependencyTrack = dependencyTrackProject.metrics;
    let trivy = emptySeverity();
    let cosignSigned = false;
    let kyvernoPolicies = { enforcedPolicies: [] as string[] };
    const partialErrors: string[] = [];
    try {
        trivy = await trivyClient.scan(imageTag);
    }
    catch (e) {
        partialErrors.push(e instanceof Error ? e.message : String(e));
    }
    try {
        cosignSigned = await cosignClient.isSigned(imageTag, { timeoutMs: 8000 });
    }
    catch (e) {
        partialErrors.push(e instanceof Error ? e.message : String(e));
    }
    try {
        kyvernoPolicies = await getKyvernoPolicyStatus(["require-signed-images", "require-non-root"]);
    }
    catch (e) {
        partialErrors.push(e instanceof Error ? e.message : String(e));
    }
    let opaAllowed = true;
    try {
        opaAllowed = await opaClient.isAllowed(imageTag, cosignSigned);
    }
    catch (e) {
        partialErrors.push(e instanceof Error ? e.message : String(e));
    }
    const severityPenalty = dependencyTrack.critical * 15 +
        dependencyTrack.high * 8 +
        dependencyTrack.medium * 3 +
        trivy.critical * 20 +
        trivy.high * 10 +
        trivy.medium * 4 +
        trivy.low * 1;
    const gatePenalty = (sonar.status === "FAILED" ? 20 : 0) +
        (!cosignSigned ? 20 : 0) +
        (!opaAllowed ? 20 : 0);
    const securityScore = score(100, severityPenalty + gatePenalty);
    const integrationHints = buildIntegrationHints(project, sonar.status, dependencyTrackProject.projectUuid);
    const securitySummary = partialErrors.length > 0
        ? `${integrationHints} Partial errors: ${partialErrors.join("; ").slice(0, 280)}`
        : dependencyTrack.critical > 0
            ? `${dependencyTrack.critical} critical vulnerabilities found in Dependency-Track.`
            : dependencyTrack.high > 0
                ? `${dependencyTrack.high} high vulnerabilities detected in Dependency-Track.`
                : integrationHints;
    const policyEngine = policyEngineLabel();
    const policyValidated = policyEngine === "None"
        ? true
        : policyEngine === "Kyverno"
            ? env.KYVERNO_POLICIES_ENABLED === "true" &&
                kyvernoPolicies.enforcedPolicies.includes("require-signed-images") &&
                kyvernoPolicies.enforcedPolicies.includes("require-non-root") &&
                cosignSigned
            : opaAllowed;
    const deploymentAllowed = cosignSigned && policyValidated;
    const enforcementSummary = !cosignSigned
        ? "Deployment blocked: image is not signed with Cosign."
        : !policyValidated
            ? `${policyEngine} policy rejected this workload because the image is not trusted or policy requirements were not met.`
            : `${policyEngine} policy validation passed. Deployment is allowed.`;
    return {
        qualityGateStatus: sonar.status,
        dependencyTrack,
        dependencyTrackProjectUuid: dependencyTrackProject.projectUuid,
        dependencyTrackProjectName: dependencyTrackProject.projectName,
        dependencyTrackFindings: dependencyTrackProject.findings,
        securitySummary,
        imageSecurity: {
            imageRef: imageTag,
            signed: cosignSigned,
            verified: cosignSigned,
            verifier: "Cosign"
        },
        securityEnforcement: {
            policyEngine,
            policyValidated,
            deploymentAllowed,
            summary: enforcementSummary
        },
        trivy,
        cosignSigned,
        opaViolations: opaAllowed ? 0 : 1,
        securityScore
    };
}

export async function getSecurityMetrics(projectId: string): Promise<SecurityMetrics> {
    const project = await getProjectById(projectId);
    return buildSecurityMetrics(project);
}
