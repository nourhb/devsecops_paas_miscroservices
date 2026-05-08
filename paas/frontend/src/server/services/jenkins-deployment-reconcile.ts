import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { getBuildBackend } from "@/server/build-backend";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import { promoteDeploymentAfterJenkinsSuccess } from "@/server/services/cluster-deploy-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
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
    const baseline = deployment.priorJenkinsBuildNumber ?? null;
    let buildNum = deployment.jenkinsBuildNumber;
    if (buildNum === null) {
        const summary = await jenkinsClient.getLastBuildSummary(projectName, projectId, "deploy");
        const candidate = summary ? normalizeBuildNumber(summary.number, baseline) : null;
        if (candidate !== null) {
            buildNum = candidate;
            await prisma.deployment.update({
                where: { id: deploymentId },
                data: { jenkinsBuildNumber: buildNum }
            });
        }
    }
    if (buildNum === null) {
        return;
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
        return;
    }
    const console = (await jenkinsClient.getBuildConsoleText(projectName, projectId, buildNum, "deploy")) ?? deployment.logs ?? "";
    const logTail = console.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    if (meta.result === "SUCCESS") {
        await promoteDeploymentAfterJenkinsSuccess(deploymentId, projectId, projectName, buildNum, logTail);
        return;
    }
    const msg = meta.result === "ABORTED"
        ? "Jenkins pipeline was cancelled or aborted."
        : `Build backend finished with result: ${meta.result ?? "UNKNOWN"}`;
    await recordDeploymentFailure(deploymentId, projectId, {
        reason: DeploymentFailureReason.JENKINS,
        message: msg,
        logs: `${logTail}\n\n${msg}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
    });
}
