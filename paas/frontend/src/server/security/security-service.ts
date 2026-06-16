import type { SecurityIntegrationProbe, SecurityMetrics } from "@/types";
import { DeploymentJobStatus, type Project } from "@prisma/client";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { buildDeployImageRepository, sanitizeDeployImageName } from "@/server/deploy/deploy-image";
import { normalizeHarborImageRef } from "@/server/deploy/harbor-registry-host";
import { getKyvernoPolicyStatus } from "@/server/integrations/kubernetes-client";
import { cosignClient, dependencyTrackClient, jenkinsClient, opaClient, resolveLatestDeployArtifactImage, sonarQubeClient, trivyClient } from "@/server/integrations/devsecops-clients";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { parsePipelineVerificationLogs } from "@/server/jenkins/pipeline-step-verification";
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
        securityScore: 0,
        integrationProbes: [],
        pipelineVerification: {
            jenkinsChecks: [],
            deployChecks: [],
            buildComplete: null,
            artifactImage: null
        },
        buildContext: {
            jenkinsBuildNumber: null,
            jenkinsBuildResult: null,
            deploymentStatus: project.lastDeploymentStatus ?? null,
            deploymentFailureReason: null,
            deploymentFailureMessage: null
        },
        securityLogExcerpt: ""
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

function normalizeCosignDigestRef(imageTag: string, rawDigest: string): string {
    const digest = rawDigest.trim();
    if (!digest) {
        return "";
    }
    if (digest.includes("/") || digest.includes("@")) {
        return digest;
    }
    if (/^sha256:[a-f0-9]{64}$/i.test(digest)) {
        const repo = imageTag.replace(/:[^@]+$/, "").replace(/@.*$/, "").trim();
        return repo ? `${repo}@${digest}` : digest;
    }
    return digest;
}

async function resolveLatestDeploymentLogs(project: Project, maxJenkinsChars = DEPLOYMENT_LOG_TAIL_MAX_CHARS): Promise<{
    logs: string;
    jenkinsBuildNumber: number | null;
    deploymentStatus: string | null;
    failureReason: string | null;
    failureMessage: string | null;
}> {
    const recent = await prisma.deployment.findFirst({
        where: { projectId: project.id },
        orderBy: { createdAt: "desc" },
        select: {
            logs: true,
            jenkinsBuildNumber: true,
            status: true,
            failureReason: true,
            failureMessage: true
        }
    });
    let logs = recent?.logs ?? "";
    const buildNum = recent?.jenkinsBuildNumber ?? null;
    const needsJenkins =
        buildNum != null &&
        !/PAAS_STEP_(OK|WARN|FAIL|SKIP)/i.test(logs);
    if (needsJenkins) {
        try {
            const console = await jenkinsClient.getBuildConsoleText(
                project.projectName,
                project.id,
                buildNum,
                "deploy"
            );
            if (console?.trim()) {
                logs = console.length <= maxJenkinsChars
                    ? console
                    : console.slice(-maxJenkinsChars);
            }
        }
        catch {
        }
    }
    return {
        logs,
        jenkinsBuildNumber: buildNum,
        deploymentStatus: recent?.status ?? null,
        failureReason: recent?.failureReason ?? null,
        failureMessage: recent?.failureMessage ?? null
    };
}

async function deploymentLogsForCosign(project: Project): Promise<string> {
    return (await resolveLatestDeploymentLogs(project)).logs;
}

const SECURITY_LOG_LINE = /PAAS_STEP_|PAAS_BUILD_COMPLETE|PAAS_(COSIGN|IMAGE)_DIGEST|PAAS_ARTIFACT_IMAGE|PAAS_DEPLOY_VERIFY|sonar|dependency-track|cyclonedx|dependency-check|\bSCA\b|cosign|trivy|\bzap\b|dast|quality gate|Not authorized|EXECUTION SUCCESS|ANALYSIS SUCCESSFUL|WARN.*step=|FAIL.*step=/i;

function extractSecurityLogExcerpt(logs: string, maxChars = 12000): string {
    const text = logs.trim();
    if (!text) {
        return "No deployment or Jenkins logs stored yet. Trigger a build from Pipeline, then reopen Security.";
    }
    const matched = text
        .split(/\r?\n/)
        .filter((line) => SECURITY_LOG_LINE.test(line))
        .join("\n");
    const excerpt = matched.trim() || text;
    return excerpt.length > maxChars ? excerpt.slice(-maxChars) : excerpt;
}

function buildIntegrationProbes(input: {
    sonarStatus: "PASSED" | "FAILED" | "UNKNOWN";
    sonarMatchedKey: string | null;
    dtProjectUuid: string | null;
    trivy: ReturnType<typeof emptySeverity>;
    trivyError: string | null;
    cosignSigned: boolean;
    policyEngine: ReturnType<typeof policyEngineLabel>;
    policyValidated: boolean;
    kyvernoEnforcedPolicies: string[];
    opaAllowed: boolean;
    partialErrors: string[];
}): SecurityIntegrationProbe[] {
    const sonarConfigured = Boolean(env.SONAR_BASE_URL?.trim() && env.SONAR_TOKEN?.trim());
    const dtConfigured = Boolean(env.DEPENDENCY_TRACK_BASE_URL?.trim() && env.DEPENDENCY_TRACK_API_KEY?.trim());
    const trivyConfigured = Boolean(env.TRIVY_BASE_URL?.trim() || (env.HARBOR_BASE_URL?.trim() && env.HARBOR_USERNAME?.trim()));
    const cosignConfigured = Boolean(env.COSIGN_PRIVATE_KEY?.trim() || env.COSIGN_CREDENTIALS_ID?.trim());
    const probes: SecurityIntegrationProbe[] = [
        {
            tool: "SonarQube (Step 5)",
            configured: sonarConfigured,
            status: !sonarConfigured
                ? "SKIPPED"
                : input.sonarStatus === "PASSED"
                    ? "OK"
                    : input.sonarStatus === "FAILED"
                        ? "FAIL"
                        : "UNKNOWN",
            detail: !sonarConfigured
                ? "SONAR_BASE_URL / SONAR_TOKEN not set on PaaS frontend."
                : input.sonarMatchedKey
                    ? `Quality gate ${input.sonarStatus} for key ${input.sonarMatchedKey}.`
                    : "No Sonar analysis found — run full pipeline (Step 5)."
        },
        {
            tool: "Dependency-Track (Step 4)",
            configured: dtConfigured,
            status: !dtConfigured
                ? "SKIPPED"
                : input.dtProjectUuid
                    ? "OK"
                    : "UNKNOWN",
            detail: !dtConfigured
                ? "DEPENDENCY_TRACK_BASE_URL / API key not set."
                : input.dtProjectUuid
                    ? `Project linked (${input.dtProjectUuid.slice(0, 8)}…).`
                    : "No SBOM project — Step 4 must upload bom.json."
        },
        {
            tool: "Trivy / Harbor scan",
            configured: trivyConfigured,
            status: !trivyConfigured
                ? "SKIPPED"
                : input.trivyError
                    ? "WARN"
                    : input.trivy.critical + input.trivy.high > 0
                        ? "WARN"
                        : "OK",
            detail: input.trivyError
                ? input.trivyError.slice(0, 220)
                : `Critical ${input.trivy.critical}, high ${input.trivy.high}, medium ${input.trivy.medium}, low ${input.trivy.low}.`
        },
        {
            tool: "Cosign (Step 9)",
            configured: cosignConfigured,
            status: !cosignConfigured ? "SKIPPED" : input.cosignSigned ? "OK" : "FAIL",
            detail: !cosignConfigured
                ? "Cosign key not configured in Jenkins/PaaS env."
                : input.cosignSigned
                    ? "Image signature verified (or Jenkins Step 9 marker trusted)."
                    : "Image not signed — deploy may be blocked by policy."
        },
        {
            tool: `${input.policyEngine} policy`,
            configured: input.policyEngine !== "None",
            status: input.policyEngine === "None"
                ? "SKIPPED"
                : input.policyValidated
                    ? "OK"
                    : "FAIL",
            detail: input.policyEngine === "None"
                ? "POLICY_ENGINE=none — policy checks disabled."
                : input.policyValidated
                    ? "Policy validation passed."
                    : input.opaAllowed === false
                        ? "OPA rejected this image."
                        : input.cosignSigned &&
                            input.policyEngine === "Kyverno" &&
                            (!input.kyvernoEnforcedPolicies.includes("require-signed-images") ||
                                !input.kyvernoEnforcedPolicies.includes("require-non-root"))
                            ? "Kyverno ClusterPolicies not in Enforce (or PaaS RBAC cannot list clusterpolicies — check cluster policy sync)."
                            : "Policy requirements not met (e.g. unsigned image)."
        }
    ];
    if (input.partialErrors.length > 0) {
        probes.push({
            tool: "Integration errors",
            configured: true,
            status: "WARN",
            detail: input.partialErrors.join("; ").slice(0, 280)
        });
    }
    return probes;
}

async function resolveCosignSigned(project: Project, imageTag: string, prefetchedLogs?: string): Promise<boolean> {
    const verifyTimeoutMs = 15000;
    if (await cosignClient.isSigned(imageTag, { timeoutMs: verifyTimeoutMs })) {
        return true;
    }
    const logs = prefetchedLogs ?? await deploymentLogsForCosign(project);
    const rawDigest = logs.match(/PAAS_COSIGN_DIGEST=(\S+)/)?.[1]?.trim()
        ?? logs.match(/PAAS_IMAGE_DIGEST=(\S+)/)?.[1]?.trim()
        ?? "";
    const digestRef = normalizeCosignDigestRef(imageTag, rawDigest);
    if (digestRef && await cosignClient.isSigned(digestRef, { timeoutMs: verifyTimeoutMs })) {
        return true;
    }
    const trustJenkinsCosign = process.env.COSIGN_LAB_TRUST_JENKINS_STEP9 !== "false";
    if (trustJenkinsCosign && (
        /PAAS_STEP_OK step=9 id=cosign/i.test(logs) ||
        /\[cosign\] signing digest /i.test(logs)
    )) {
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

function sonarProjectKeysFromLogs(logs: string): string[] {
    const keys: string[] = [];
    for (const m of logs.matchAll(/analysis submitted for projectKey=(\S+)/gi)) {
        keys.push(m[1].replace(/[,;.`'"]+$/, ""));
    }
    for (const m of logs.matchAll(/sonar\.projectKey=(\S+)/gi)) {
        keys.push(m[1].trim());
    }
    return [...new Set(keys.filter((k) => k.trim()))];
}

async function resolveSonarQualityGate(project: Project, logKeys: string[] = []): Promise<{
    status: "PASSED" | "FAILED" | "UNKNOWN";
    matchedKey: string | null;
}> {
    const keys = [...new Set([...logKeys, ...integrationProjectKeys(project)])];
    for (const key of keys) {
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

async function buildIntegrationNotes(project: Project, sonarStatus: string, dtProjectUuid: string | null, scaFromLogs?: {
    level: string;
    message: string;
} | null, sonarFromLogs?: {
    level: string;
    message: string;
} | null): Promise<string> {
    const notes: string[] = [];
    if (!env.SONAR_BASE_URL?.trim() || !env.SONAR_TOKEN?.trim()) {
        notes.push("Configure SONAR_BASE_URL and SONAR_TOKEN on the PaaS frontend.");
    }
    else if (sonarStatus === "UNKNOWN") {
        if (sonarFromLogs?.level === "SKIP") {
            notes.push(`SonarQube Step 5 skipped (${sonarFromLogs.message}).`);
        }
        else if (sonarFromLogs?.level === "WARN" || sonarFromLogs?.level === "FAIL") {
            notes.push(`SonarQube Step 5 ${sonarFromLogs.level}: ${sonarFromLogs.message}`);
        }
        else if (!sonarFromLogs) {
            notes.push("SonarQube: no Step 5 marker in the last Jenkins build.");
        }
        else {
            notes.push(`SonarQube: analysis may still be processing for project key ${project.projectName}.`);
        }
        if (!(await sonarTokenLooksValid())) {
            notes.push("SonarQube: SONAR_TOKEN rejected.");
        }
    }
    if (!env.DEPENDENCY_TRACK_BASE_URL?.trim() || !env.DEPENDENCY_TRACK_API_KEY?.trim()) {
        notes.push("Configure DEPENDENCY_TRACK_BASE_URL and DEPENDENCY_TRACK_API_KEY on the PaaS frontend.");
    }
    else if (!dtProjectUuid) {
        if (scaFromLogs?.level === "SKIP") {
            notes.push(`Dependency-Track Step 4 skipped (${scaFromLogs.message}).`);
        }
        else if (scaFromLogs?.level === "WARN" || scaFromLogs?.level === "FAIL") {
            notes.push(`Dependency-Track Step 4 ${scaFromLogs.level}: ${scaFromLogs.message}`);
        }
        else if (!scaFromLogs) {
            notes.push("Dependency-Track: no Step 4 marker in last build.");
        }
        else {
            notes.push("Dependency-Track: Step 4 ran but no project linked yet.");
        }
    }
    if (env.JENKINS_PAAS_FAST_PIPELINE === "true" && env.PAAS_ALLOW_FAST_PIPELINE === "true") {
        notes.push("JENKINS_PAAS_FAST_PIPELINE=true skips Sonar and SCA steps.");
    }
    if (notes.length === 0) {
        return "Security integrations reachable.";
    }
    return notes.join(" ");
}

async function resolveSecurityImageRef(project: Project): Promise<string> {
    const stored = project.imageTag?.trim();
    if (stored && stored.includes("/") && stored.includes(":")) {
        return normalizeHarborImageRef(stored);
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
    const [imageTag, deploymentLogBundle] = await Promise.all([
        resolveSecurityImageRef(project),
        resolveLatestDeploymentLogs(project, 80_000)
    ]);
    const parsedLogs = parsePipelineVerificationLogs(deploymentLogBundle.logs);
    const securitySteps = parsedLogs.jenkinsChecks.filter((c) => [4, 5, 9, 10].includes(c.step));
    const sonarFromLogs = securitySteps.find((c) => c.step === 5);
    const scaFromLogs = securitySteps.find((c) => c.step === 4);
    const cosignFromLogs = securitySteps.find((c) => c.step === 9);

    const partialErrors: string[] = [];
    let trivyError: string | null = null;

    const sonarLogKeys = sonarProjectKeysFromLogs(deploymentLogBundle.logs);

    const [sonar, dependencyTrackProject, trivyResult, cosignSigned, kyvernoPolicies] = await Promise.all([
        resolveSonarQualityGate(project, sonarLogKeys),
        resolveDependencyTrackMetrics(project),
        trivyClient.scan(imageTag).catch((e) => {
            const msg = e instanceof Error ? e.message : String(e);
            trivyError = msg;
            partialErrors.push(msg);
            return emptySeverity();
        }),
        resolveCosignSigned(project, imageTag, deploymentLogBundle.logs).catch((e) => {
            partialErrors.push(e instanceof Error ? e.message : String(e));
            return false;
        }),
        getKyvernoPolicyStatus(["require-signed-images", "require-non-root"]).catch((e) => {
            partialErrors.push(e instanceof Error ? e.message : String(e));
            return { enforcedPolicies: [] as string[] };
        })
    ]);

    let opaAllowed = true;
    try {
        opaAllowed = await opaClient.isAllowed(imageTag, cosignSigned);
    }
    catch (e) {
        partialErrors.push(e instanceof Error ? e.message : String(e));
    }

    const dependencyTrack = dependencyTrackProject.metrics;
    const trivy = trivyResult;
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
    const severityPenalty = dependencyTrack.critical * 15 +
        dependencyTrack.high * 8 +
        dependencyTrack.medium * 3 +
        trivy.critical * 20 +
        trivy.high * 10 +
        trivy.medium * 4 +
        trivy.low * 1;
    const gatePenalty = (sonar.status === "FAILED" ? 20 : sonar.status === "UNKNOWN" ? 15 : 0) +
        (!dependencyTrackProject.projectUuid ? 10 : 0) +
        (!cosignSigned ? 20 : 0) +
        (!opaAllowed ? 20 : 0) +
        (!deploymentAllowed ? 15 : 0);
    const securityScore = score(100, severityPenalty + gatePenalty);
    const integrationNotes = await buildIntegrationNotes(project, sonar.status, dependencyTrackProject.projectUuid, scaFromLogs ?? null, sonarFromLogs ?? null);
    const logNotes: string[] = [];
    if (scaFromLogs?.level === "FAIL" || scaFromLogs?.level === "WARN") {
        logNotes.push(`Jenkins Step 4: ${scaFromLogs.level} — ${scaFromLogs.message}`);
    }
    if (sonarFromLogs?.level === "FAIL" || sonarFromLogs?.level === "WARN") {
        logNotes.push(`Jenkins Step 5: ${sonarFromLogs.level} — ${sonarFromLogs.message}`);
    }
    if (cosignFromLogs?.level === "FAIL" || cosignFromLogs?.level === "WARN") {
        logNotes.push(`Jenkins Step 9: ${cosignFromLogs.level} — ${cosignFromLogs.message}`);
    }
    const securitySummary = partialErrors.length > 0
        ? `${integrationNotes}${logNotes.length ? ` ${logNotes.join(" ")}` : ""} Partial errors: ${partialErrors.join("; ").slice(0, 220)}`
        : logNotes.length > 0
            ? logNotes.join(" ")
            : dependencyTrack.critical > 0
                ? `${dependencyTrack.critical} critical vulnerabilities found in Dependency-Track.`
                : dependencyTrack.high > 0
                    ? `${dependencyTrack.high} high vulnerabilities detected in Dependency-Track.`
                    : integrationNotes;
    const enforcementSummary = !cosignSigned
        ? "Deployment blocked: image is not signed with Cosign."
        : !policyValidated
            ? `${policyEngine} policy rejected this workload because the image is not trusted or policy requirements were not met.`
            : `${policyEngine} policy validation passed. Deployment is allowed.`;
    const integrationProbes = buildIntegrationProbes({
        sonarStatus: sonar.status,
        sonarMatchedKey: sonar.matchedKey,
        dtProjectUuid: dependencyTrackProject.projectUuid,
        trivy,
        trivyError,
        cosignSigned,
        policyEngine,
        policyValidated,
        kyvernoEnforcedPolicies: kyvernoPolicies.enforcedPolicies,
        opaAllowed,
        partialErrors
    });
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
        securityScore,
        integrationProbes,
        pipelineVerification: {
            jenkinsChecks: parsedLogs.jenkinsChecks,
            deployChecks: parsedLogs.deployChecks,
            buildComplete: parsedLogs.buildComplete,
            artifactImage: parsedLogs.artifactImage
        },
        buildContext: {
            jenkinsBuildNumber: deploymentLogBundle.jenkinsBuildNumber,
            jenkinsBuildResult: parsedLogs.buildComplete?.result ?? null,
            deploymentStatus: deploymentLogBundle.deploymentStatus ?? project.lastDeploymentStatus ?? null,
            deploymentFailureReason: deploymentLogBundle.failureReason,
            deploymentFailureMessage: deploymentLogBundle.failureMessage
        },
        securityLogExcerpt: extractSecurityLogExcerpt(deploymentLogBundle.logs)
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
