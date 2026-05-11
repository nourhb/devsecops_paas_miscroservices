import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { buildMetadataLines, formatArtifactReference } from "@/server/build-metadata";
import { buildAppPublicUrl } from "@/server/deploy/app-public-url";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { commitHelmValuesGitHub } from "@/server/gitops/gitops-github-service";
import { updateProject } from "@/server/projects/project-service";
import { syncArgoApplication } from "@/server/services/argocd-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
function tail(s: string): string {
    return s.length <= DEPLOYMENT_LOG_TAIL_MAX_CHARS ? s : s.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
}
interface PromoteDeploymentInput {
    provider: "jenkins" | "tekton";
    runId: string;
    runNumber: number | null;
    artifactImage: string | null;
    artifactDigest: string | null;
    buildLogTail: string;
}
async function persistFailure(deploymentId: string, projectId: string, fullLog: string, reason: DeploymentFailureReason, shortMessage: string): Promise<void> {
    const logs = tail(fullLog);
    await recordDeploymentFailure(deploymentId, projectId, {
        reason,
        message: shortMessage,
        logs
    });
}
export async function promoteDeploymentAfterJenkinsSuccess(deploymentId: string, projectId: string, projectName: string, jenkinsBuildNumber: number, jenkinsLogTail: string): Promise<void> {
    await promoteDeploymentAfterBuildSuccess(deploymentId, projectId, projectName, {
        provider: "jenkins",
        runId: String(jenkinsBuildNumber),
        runNumber: jenkinsBuildNumber,
        artifactImage: `${buildDeployImageRepository(projectName)}:${jenkinsBuildNumber}`,
        artifactDigest: null,
        buildLogTail: jenkinsLogTail
    });
}
export async function promoteDeploymentAfterBuildSuccess(deploymentId: string, projectId: string, projectName: string, input: PromoteDeploymentInput): Promise<void> {
    let imageRef = input.artifactImage;
    if (!imageRef) {
        try {
            imageRef =
                input.runNumber === null
                    ? null
                    : `${buildDeployImageRepository(projectName)}:${input.runNumber}`;
        }
        catch (error) {
            const msg = error instanceof Error ? error.message : String(error);
            await persistFailure(deploymentId, projectId, `${input.buildLogTail}\n\n[deploy] Could not build image reference: ${msg}`, DeploymentFailureReason.IMAGE_REF, msg);
            return;
        }
    }
    if (!imageRef) {
        await persistFailure(deploymentId, projectId, `${input.buildLogTail}\n\n[deploy] Build backend completed without an artifact image.`, DeploymentFailureReason.IMAGE_REF, "Build backend completed without an artifact image.");
        return;
    }
    const artifactRef = formatArtifactReference(imageRef, input.artifactDigest) ?? imageRef;
    const buildSection = [
        ...buildMetadataLines({
            provider: input.provider,
            profile: "custom",
            mode: "custom-dockerfile",
            templateName: "artifact-promotion",
            templateVersion: "runtime",
            detectionReason: "runtime",
            zeroConfig: false
        }, {
            runId: input.runId,
            runNumber: input.runNumber,
            artifactImage: imageRef,
            artifactDigest: input.artifactDigest
        }),
        tail(input.buildLogTail)
    ]
        .filter(Boolean)
        .join("\n");
    const buildPart = tail(buildSection);
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: { status: DeploymentJobStatus.SUCCESS, logs: buildPart, ...clearDeploymentFailureFields() }
    });
    await updateProject(projectId, {
        lastDeploymentStatus: "SUCCESS",
        deploymentLogs: buildPart,
        buildStatus: "PUSHING"
    });
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: { status: DeploymentJobStatus.DEPLOYING, ...clearDeploymentFailureFields() }
    });
    await updateProject(projectId, { lastDeploymentStatus: "PROMOTING" });
    const sections: string[] = [
        buildPart,
        "",
        "--- GitOps (Helm values) + Argo CD ---",
        `[image] ${artifactRef}`
    ];
    await prisma.containerImage.create({
        data: {
            projectId,
            imageRef,
            registry: "harbor",
            action: "PROMOTE",
            digest: input.artifactDigest ?? null,
            logs: buildPart
        }
    }).catch(() => null);
    try {
        const git = await commitHelmValuesGitHub(projectName, artifactRef);
        sections.push(`[gitops] committed ${git.ref}`);
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        sections.push(`[gitops] FAILED: ${msg}`);
        await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.GITOPS, msg);
        return;
    }
    sections.push(`[build-meta] paas_strict_integrations=${env.PAAS_STRICT_INTEGRATIONS}`);
    try {
        const argo = await syncArgoApplication(projectName);
        sections.push(argo.logs);
    }
    catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        const lenientIntegrations = env.PAAS_STRICT_INTEGRATIONS !== "true";
        const authzFail =
            /\bHTTP\s*401\b/i.test(msg) ||
            /\bHTTP\s*403\b/i.test(msg) ||
            /authentication failed/i.test(msg) ||
            /denied this request/i.test(msg);
        if (lenientIntegrations && authzFail) {
            sections.push(
                `[argocd] WARN: ${msg} — deployment continues (PAAS_STRICT_INTEGRATIONS is not "true"). ` +
                    "GitOps already committed; sync this Application in the Argo CD UI or grant the API token sync permission."
            );
        }
        else {
            sections.push(`[argocd] FAILED: ${msg}`);
            await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, msg);
            return;
        }
    }
    const okLog = tail(sections.join("\n"));
    const appUrl = buildAppPublicUrl(projectName);
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: {
            status: DeploymentJobStatus.DEPLOYED,
            logs: okLog,
            url: appUrl,
            ...clearDeploymentFailureFields()
        }
    });
    await updateProject(projectId, {
        lastDeploymentStatus: "DEPLOYED",
        buildStatus: "READY",
        deploymentLogs: okLog,
        imageTag: artifactRef,
        url: appUrl
    });
}
