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
import { monitorDeployment } from "@/server/services/jenkins-monitor";
import { updateProject } from "@/server/projects/project-service";

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
    if (!terminalBuild(meta)) {
        await prisma.deployment.update({
            where: { id: deploymentId },
            data: {
                status: DeploymentJobStatus.DEPLOYING,
                jenkinsBuildNumber: buildNum,
                ...clearDeploymentFailureFields()
            }
        });
        await updateProject(projectId, {
            lastDeploymentStatus: "DEPLOYING",
            buildStatus: "BUILDING"
        });
        monitorDeployment(deploymentId, buildNum);
        return;
    }
    const console = (await jenkinsClient.getBuildConsoleText(projectName, projectId, buildNum, "deploy")) ?? deployment.logs ?? "";
    const logTail = console.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    if (meta.result === "SUCCESS") {
        try {
            await promoteDeploymentAfterJenkinsSuccess(deploymentId, projectId, projectName, buildNum, logTail);
        }
        catch (error) {
            const msg = error instanceof Error ? error.message : String(error);
            await recordDeploymentFailure(deploymentId, projectId, {
                reason: DeploymentFailureReason.UNKNOWN,
                message: `[reconcile] Post-build promotion failed: ${msg}`,
                logs: `${logTail}\n\n[reconcile] ${msg}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
            });
        }
        return;
    }
    const msg = jenkinsResultUserMessage(meta.result, logTail);
    await recordDeploymentFailure(deploymentId, projectId, {
        reason: DeploymentFailureReason.JENKINS,
        message: msg,
        logs: `${logTail}\n\n${msg}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
    });
}
