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
function degradedMetrics(project: Project, message: string): SecurityMetrics {
    const imageTag = project.imageTag || project.projectName;
    const policyEngine = policyEngineLabel();
    return {
        qualityGateStatus: "UNKNOWN",
        dependencyTrack: emptySeverity(),
        dependencyTrackProjectUuid: null,
        dependencyTrackProjectName: project.projectName,
        dependencyTrackFindings: [],
        securitySummary: message.slice(0, 400),
        imageSecurity: {
            imageRef: imageTag,
            signed: false,
            verified: false,
            verifier: "Cosign"
        },
        securityEnforcement: {
            policyEngine,
            policyValidated: policyEngine === "None",
            deploymentAllowed: policyEngine === "None",
            summary: "Security integrations returned an error \u2014 values below are incomplete."
        },
        trivy: emptySeverity(),
        cosignSigned: false,
        opaViolations: 0,
        securityScore: 0
    };
}
async function buildSecurityMetrics(project: Project): Promise<SecurityMetrics> {
    const imageTag = project.imageTag || project.projectName;
    const qualityGate = await sonarQubeClient.qualityGate(project.projectName);
    const dependencyTrackProject = await dependencyTrackClient.projectMetrics(project.projectName);
    const dependencyTrack = dependencyTrackProject.metrics;
    const [trivy, cosignSigned, kyvernoPolicies] = await Promise.all([
        trivyClient.scan(imageTag),
        cosignClient.isSigned(imageTag),
        getKyvernoPolicyStatus(["require-signed-images", "require-non-root"])
    ]);
    const opaAllowed = await opaClient.isAllowed(imageTag, cosignSigned);
    const severityPenalty = dependencyTrack.critical * 15 +
        dependencyTrack.high * 8 +
        dependencyTrack.medium * 3 +
        trivy.critical * 20 +
        trivy.high * 10 +
        trivy.medium * 4 +
        trivy.low * 1;
    const gatePenalty = (qualityGate.status === "FAILED" ? 20 : 0) +
        (!cosignSigned ? 20 : 0) +
        (!opaAllowed ? 20 : 0);
    const securityScore = score(100, severityPenalty + gatePenalty);
    const securitySummary = dependencyTrack.critical > 0
        ? `${dependencyTrack.critical} critical vulnerabilities found in Dependency-Track.`
        : dependencyTrack.high > 0
            ? `${dependencyTrack.high} high vulnerabilities detected in Dependency-Track.`
            : "No critical vulnerabilities reported by Dependency-Track.";
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
        qualityGateStatus: qualityGate.status,
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
    try {
        return await buildSecurityMetrics(project);
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return degradedMetrics(project, `Could not reach one or more security backends: ${msg}`);
    }
}
