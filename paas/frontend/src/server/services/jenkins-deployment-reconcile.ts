import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { parseBuildMetadata } from "@/server/build-metadata";
import { getBuildBackend } from "@/server/build-backend";
import { jenkinsClient, usesSharedJenkinsDeployJob } from "@/server/integrations/devsecops-clients";
import { promoteDeploymentAfterJenkinsSuccess } from "@/server/services/cluster-deploy-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
import { jenkinsResultUserMessage } from "@/server/jenkins/jenkins-result-user-message";
import { resolveVerifiedArtifactImage } from "@/server/jenkins/jenkins-build-artifact";
import { monitorDeployment } from "@/server/services/jenkins-monitor";
import { updateProject } from "@/server/projects/project-service";
import { TtlCache } from "@/server/http/ttl-cache";

const jenkinsUiRefreshThrottle = new TtlCache<true>(2500);

function jenkinsConfigured(): boolean {
    return Boolean(env.JENKINS_BASE_URL && env.JENKINS_USERNAME && env.JENKINS_API_TOKEN);
}

function terminalBuild(meta: {
    result: string | null;
    building: boolean;
}): boolean {
    return !meta.building && meta.result !== null;
}

function normalizeBuildNumber(reported: number | null, baseline: number | null): number | null {
    if (reported === null) {
        return null;
    }
    if (baseline !== null && reported <= baseline) {
        return null;
    }
    return reported;
}

export function extractJenkinsRunFromLogs(logs: string | null | undefined): number | null {
    const text = String(logs ?? "");
    const direct = text.match(/\[jenkins\]\s*New run #(\d+)/i);
    if (direct) {
        const n = Number.parseInt(direct[1], 10);
        if (Number.isFinite(n)) {
            return n;
        }
    }
    const metadata = parseBuildMetadata(text);
    if (metadata.runNumber != null && Number.isFinite(metadata.runNumber)) {
        return metadata.runNumber;
    }
    return null;
}

async function resolveDeployBuildNumber(deployment: {
    id: string;
    jenkinsBuildNumber: number | null;
    priorJenkinsBuildNumber: number | null;
    logs: string | null;
    createdAt: Date;
    project: {
        projectName: string;
        id: string;
    };
}): Promise<number | null> {
    const { projectName, id: projectId } = deployment.project;
    const baseline = deployment.priorJenkinsBuildNumber ?? null;
    const fromColumn = deployment.jenkinsBuildNumber;
    if (fromColumn != null) {
        if (await jenkinsClient.verifyDeployBuildBelongsToProject(projectName, projectId, fromColumn)) {
            return fromColumn;
        }
        await prisma.deployment.update({
            where: { id: deployment.id },
            data: { jenkinsBuildNumber: null }
        });
    }
    const fromLogs = extractJenkinsRunFromLogs(deployment.logs);
    if (fromLogs != null && (baseline == null || fromLogs > baseline)) {
        if (await jenkinsClient.verifyDeployBuildBelongsToProject(projectName, projectId, fromLogs)) {
            return fromLogs;
        }
    }
    const fromScan = await jenkinsClient.findDeployBuildForProject(projectName, projectId, {
        baseline,
        afterMs: deployment.createdAt.getTime() - 120_000
    });
    if (fromScan != null) {
        return fromScan;
    }
    if (usesSharedJenkinsDeployJob()) {
        return null;
    }
    const summary = await jenkinsClient.getLastBuildSummary(projectName, projectId, "deploy");
    return summary ? normalizeBuildNumber(summary.number, baseline) : null;
}

/** Lightweight Jenkins poll for UI status — does not run GitOps promotion. */
export async function refreshProjectJenkinsDisplayStatus(projectId: string): Promise<void> {
    if (!jenkinsConfigured() || getBuildBackend().provider !== "jenkins") {
        return;
    }
    if (jenkinsUiRefreshThrottle.get(projectId)) {
        return;
    }
    jenkinsUiRefreshThrottle.set(projectId, true);
    const project = await prisma.project.findUnique({
        where: { id: projectId },
        select: { buildStatus: true, lastDeploymentStatus: true }
    });
    if (!project) {
        return;
    }
    const bs = (project.buildStatus || "").toUpperCase();
    const ds = (project.lastDeploymentStatus || "").toUpperCase();
    const busy = ["QUEUED", "BUILDING", "PUSHING"].includes(bs) || ["QUEUED", "DEPLOYING", "PROMOTING", "PENDING"].includes(ds);
    if (!busy) {
        return;
    }
    const deployment = await prisma.deployment.findFirst({
        where: {
            projectId,
            status: { in: [DeploymentJobStatus.PENDING, DeploymentJobStatus.DEPLOYING] }
        },
        orderBy: { createdAt: "desc" },
        include: { project: true }
    });
    if (!deployment) {
        if (bs === "BUILDING" || bs === "QUEUED") {
            const terminal = ["SUCCESS", "READY", "FAILED"].includes(bs);
            if (!terminal && ["SUCCESS", "DEPLOYED", "FAILED", "ROLLED_BACK"].includes(ds)) {
                await updateProject(projectId, {
                    buildStatus: ds === "FAILED" ? "FAILED" : "SUCCESS"
                });
            }
        }
        return;
    }
    const buildNum = await resolveDeployBuildNumber(deployment);
    if (buildNum === null) {
        return;
    }
    const { projectName, id: pid } = deployment.project;
    const meta = await jenkinsClient.getBuildApiJson(projectName, pid, buildNum, "deploy");
    if (!meta) {
        return;
    }
    if (!terminalBuild(meta)) {
        await updateProject(projectId, {
            buildStatus: "BUILDING",
            lastDeploymentStatus: "DEPLOYING",
            deploymentLogs: deployment.logs ?? undefined
        });
        return;
    }
    if (meta.result === "SUCCESS") {
        await updateProject(projectId, {
            buildStatus: "SUCCESS",
            lastDeploymentStatus: deployment.status === DeploymentJobStatus.DEPLOYING ? "PROMOTING" : "SUCCESS"
        });
    }
    else {
        await updateProject(projectId, {
            buildStatus: "FAILED",
            lastDeploymentStatus: "FAILED"
        });
    }
}

export async function reconcileJenkinsDeploymentRecord(deploymentId: string): Promise<void> {
    if (!jenkinsConfigured() || getBuildBackend().provider !== "jenkins") {
        return;
    }
    const deployment = await prisma.deployment.findUnique({
        where: { id: deploymentId },
        include: { project: true }
    });
    if (!deployment) {
        return;
    }
    if (deployment.status !== DeploymentJobStatus.PENDING && deployment.status !== DeploymentJobStatus.DEPLOYING) {
        return;
    }
    const { projectName, id: projectId } = deployment.project;
    let buildNum = await resolveDeployBuildNumber(deployment);
    if (buildNum === null) {
        return;
    }
    if (buildNum !== deployment.jenkinsBuildNumber) {
        await prisma.deployment.update({
            where: { id: deploymentId },
            data: { jenkinsBuildNumber: buildNum }
        });
    }
    const meta = await jenkinsClient.getBuildApiJson(projectName, projectId, buildNum, "deploy");
    if (!meta) {
        return;
    }
    const console = (await jenkinsClient.getBuildConsoleText(projectName, projectId, buildNum, "deploy")) ?? deployment.logs ?? "";
    const logTail = console.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    if (!terminalBuild(meta)) {
        await prisma.deployment.update({
            where: { id: deploymentId },
            data: {
                status: DeploymentJobStatus.DEPLOYING,
                jenkinsBuildNumber: buildNum,
                logs: logTail,
                ...clearDeploymentFailureFields()
            }
        });
        await updateProject(projectId, {
            lastDeploymentStatus: "DEPLOYING",
            buildStatus: "BUILDING",
            deploymentLogs: logTail
        });
        monitorDeployment(deploymentId, buildNum);
        return;
    }
    if (meta.result === "SUCCESS") {
        await prisma.deployment.update({
            where: { id: deploymentId },
            data: {
                status: DeploymentJobStatus.DEPLOYING,
                jenkinsBuildNumber: buildNum,
                logs: logTail,
                ...clearDeploymentFailureFields()
            }
        });
        await updateProject(projectId, {
            lastDeploymentStatus: "PROMOTING",
            buildStatus: "SUCCESS",
            deploymentLogs: logTail
        });
        void promoteDeploymentAfterJenkinsSuccess(deploymentId, projectId, projectName, buildNum, logTail).catch(async (error) => {
            const msg = error instanceof Error ? error.message : String(error);
            await recordDeploymentFailure(deploymentId, projectId, {
                reason: DeploymentFailureReason.UNKNOWN,
                message: `[reconcile] Post-build promotion failed: ${msg}`,
                logs: `${logTail}\n\n[reconcile] ${msg}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
            });
        });
        return;
    }
    const msg = jenkinsResultUserMessage(meta.result, logTail);
    await recordDeploymentFailure(deploymentId, projectId, {
        reason: DeploymentFailureReason.JENKINS,
        message: msg,
        logs: `${logTail}\n\n${msg}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
    });
}
