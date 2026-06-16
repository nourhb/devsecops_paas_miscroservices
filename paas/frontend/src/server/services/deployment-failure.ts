import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import { updateProject } from "@/server/projects/project-service";
import { notifyPipelineFailureEmail } from "@/server/notifications/pipeline-failure-notify";
const MESSAGE_MAX = 2000;
export async function recordDeploymentFailure(deploymentId: string, projectId: string, options: {
    reason: DeploymentFailureReason;
    message: string;
    logs: string;
}): Promise<void> {
    const prior = await prisma.deployment.findUnique({
        where: { id: deploymentId },
        select: {
            status: true,
            project: {
                select: {
                    projectName: true,
                    createdBy: {
                        select: {
                            email: true,
                            fullName: true
                        }
                    }
                }
            },
            triggeredBy: {
                select: {
                    email: true
                }
            }
        }
    });
    const logs = options.logs.length <= DEPLOYMENT_LOG_TAIL_MAX_CHARS
        ? options.logs
        : options.logs.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    const failureMessage = options.message.length <= MESSAGE_MAX ? options.message : `${options.message.slice(0, MESSAGE_MAX)}…`;
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: {
            status: DeploymentJobStatus.FAILED,
            logs,
            failureReason: options.reason,
            failureMessage
        }
    });
    const failedDuringJenkinsRun = options.reason === DeploymentFailureReason.JENKINS ||
        options.reason === DeploymentFailureReason.TIMEOUT ||
        options.reason === DeploymentFailureReason.TRIGGER ||
        options.reason === DeploymentFailureReason.UNKNOWN;
    await updateProject(projectId, {
        lastDeploymentStatus: "FAILED",
        deploymentLogs: logs,
        ...(failedDuringJenkinsRun ? { buildStatus: "FAILED" } : {})
    });
    const firstFailureTransition = prior?.status !== DeploymentJobStatus.FAILED;
    if (firstFailureTransition && prior?.project?.createdBy?.email) {
        void notifyPipelineFailureEmail({
            deploymentId,
            projectId,
            projectName: prior.project.projectName,
            ownerEmail: prior.project.createdBy.email,
            ownerName: prior.project.createdBy.fullName,
            triggeredByEmail: prior.triggeredBy?.email ?? null,
            reason: options.reason,
            message: failureMessage,
            logs
        }).catch((err) => {
            console.error("[pipeline-failure-email]", deploymentId, err);
        });
    }
}
export function clearDeploymentFailureFields(): {
    failureReason: null;
    failureMessage: null;
} {
    return { failureReason: null, failureMessage: null };
}
