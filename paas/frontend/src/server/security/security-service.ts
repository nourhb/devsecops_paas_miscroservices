import type { SecurityMetrics } from "@/types";
import { DeploymentJobStatus, type Project } from "@prisma/client";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { buildDeployImageRepository, sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import { getKyvernoPolicyStatus } from "@/server/integrations/kubernetes-client";
import { cosignClient, dependencyTrackClient, opaClient, resolveLatestDeployArtifactImage, sonarQubeClient, trivyClient } from "@/server/integrations/devsecops-clients";
import { getProjectById } from "@/server/projects/project-service";

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
            summary: "Security integrations returned an error — values below are incomplete."
        },
        trivy: emptySeverity(),
        cosignSigned: false,
        opaViolations: 0,
        securityScore: 0
    };
}

function integrationProjectKeys(project: Project): string[] {
    const imageSlug = project.imageTag?.includes("/")
        ? project.imageTag.split("/").pop()?.split(":")[0]?.trim()
        : "";
    return [...new Set([
        project.id,
        project.projectName,
        sanitizeDeployImageName(project.projectName),
        imageSlug || ""
    ].filter((k) => k.trim()))];
}

/** Dependency-Track projects are created from Harbor image slug (dtProjectNameForUpload), not always UUID. */
function dependencyTrackLookupKeys(project: Project): string[] {
    const imageSlug = project.imageTag?.includes("/")
        ? project.imageTag.split("/").pop()?.split(":")[0]?.trim()
        : "";
    return [...new Set([
        sanitizeDeployImageName(project.projectName),
        project.projectName,
        imageSlug || "",
        project.id
    ].filter((k) => k.trim()))];
}

async function resolveCosignSigned(project: Project, imageTag: string): Promise<boolean> {
    if (await cosignClient.isSigned(imageTag, { timeoutMs: 12000 })) {
        return true;
    }
    const recent = await prisma.deployment.findFirst({
        where: { projectId: project.id },
        orderBy: { createdAt: "desc" },
        select: { logs: true }
    });
    const logs = recent?.logs ?? "";
    const digest = logs.match(/PAAS_COSIGN_DIGEST=(\S+)/)?.[1]?.trim();
    if (digest && await cosignClient.isSigned(digest, { timeoutMs: 12000 })) {
        return true;
    }
    const trustJenkinsCosign = process.env.COSIGN_LAB_TRUST_JENKINS_STEP9 !== "false";
    if (trustJenkinsCosign && /PAAS_STEP_OK step=9[^\n]*cosign/i.test(logs)) {
        return true;
    }
    return false;
}

async function sonarTokenLooksValid(): Promise<boolean> {
    if (!env.SONAR_BASE_URL?.trim() || !env.SONAR_TOKEN?.trim()) {
        return false;
    }
    try {
        const { integrationFetch } = await import("@/server/http/integration-fetch");
        const response = await integrationFetch(`${env.SONAR_BASE_URL.replace(/\/$/, "")}/api/authentication/validate`, {
            method: "GET",
            headers: {
                Authorization: `Basic ${Buffer.from(`${env.SONAR_TOKEN}:`).toString("base64")}`
            }
        });
        return response.ok;
    }
    catch {
        return false;
    }
}

async function resolveSonarQualityGate(project: Project): Promise<{
    status: "PASSED" | "FAILED" | "UNKNOWN";
    matchedKey: string | null;
}> {
    for (const key of integrationProjectKeys(project)) {
        try {
            const result = await sonarQubeClient.qualityGate(key);
            if (result.status === "PASSED" || result.status === "FAILED") {
                return { status: result.status, matchedKey: key };
            }
        }
        catch {
            continue;
        }
    }
    return { status: "UNKNOWN", matchedKey: null };
}

async function resolveDependencyTrackMetrics(project: Project) {
    for (const key of dependencyTrackLookupKeys(project)) {
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

async function buildIntegrationHints(project: Project, sonarStatus: string, dtProjectUuid: string | null): Promise<string> {
    const hints: string[] = [];
    if (!env.SONAR_BASE_URL?.trim() || !env.SONAR_TOKEN?.trim()) {
        hints.push("PaaS frontend: set SONAR_BASE_URL and SONAR_TOKEN in docker-compose.env, then run sync-paas-frontend-env-k8s.sh.");
    }
    else if (sonarStatus === "UNKNOWN") {
        hints.push("SonarQube: no analysis for this project yet — run a full Jenkins pipeline (Step 5; JENKINS_PAAS_FAST_PIPELINE=false).");
        if (!(await sonarTokenLooksValid())) {
            hints.push("SonarQube: SONAR_TOKEN rejected — run: bash paas/scripts/regenerate-sonar-token-lab.sh");
        }
    }
    if (!env.DEPENDENCY_TRACK_BASE_URL?.trim() || !env.DEPENDENCY_TRACK_API_KEY?.trim()) {
        hints.push("PaaS frontend: set DEPENDENCY_TRACK_BASE_URL and DEPENDENCY_TRACK_API_KEY, then sync env to the frontend pod.");
    }
    else if (!dtProjectUuid) {
        hints.push("Dependency-Track: no SBOM project — Step 4 must upload bom.json (Jenkins needs DEPENDENCY_TRACK_API_KEY).");
    }
    if (env.JENKINS_PAAS_FAST_PIPELINE === "true") {
        hints.push("JENKINS_PAAS_FAST_PIPELINE=true skips Sonar and SCA steps.");
    }
    if (hints.length === 0) {
        return "Security integrations reachable.";
    }
    return hints.join(" ");
}

async function resolveSecurityImageRef(project: Project): Promise<string> {
    const stored = project.imageTag?.trim();
    if (stored && stored.includes("/") && stored.includes(":")) {
        return stored;
    }
    const recent = await prisma.deployment.findFirst({
        where: {
            projectId: project.id,
            jenkinsBuildNumber: { not: null },
            status: {
                in: [
                    DeploymentJobStatus.DEPLOYED,
                    DeploymentJobStatus.SUCCESS,
                    DeploymentJobStatus.DEPLOYING,
                    DeploymentJobStatus.PENDING
                ]
            }
        },
        orderBy: { createdAt: "desc" },
        select: { jenkinsBuildNumber: true }
    });
    if (recent?.jenkinsBuildNumber != null) {
        return `${buildDeployImageRepository(project.projectName)}:${recent.jenkinsBuildNumber}`;
    }
    const latest = await resolveLatestDeployArtifactImage(project.projectName, project.id);
    return latest?.trim() || stored || `${buildDeployImageRepository(project.projectName)}:latest`;
}

async function buildSecurityMetrics(project: Project): Promise<SecurityMetrics> {
    const imageTag = await resolveSecurityImageRef(project);
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
        cosignSigned = await resolveCosignSigned(project, imageTag);
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
    const integrationHints = await buildIntegrationHints(project, sonar.status, dependencyTrackProject.projectUuid);
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
    try {
        return await buildSecurityMetrics(project);
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        return degradedMetrics(project, msg);
    }
}
