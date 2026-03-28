import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { updateProject } from "@/server/projects/project-service";

const LOG_TAIL = 5000;
const MESSAGE_MAX = 2000;

export function humanizeFailureReason(reason: DeploymentFailureReason | null): string {
  if (!reason) {
    return "";
  }
  const labels: Record<DeploymentFailureReason, string> = {
    JENKINS: "Jenkins",
    GITOPS: "GitOps",
    ARGOCD: "Argo CD",
    IMAGE_REF: "Image configuration",
    TRIGGER: "Deploy trigger",
    TIMEOUT: "Timeout",
    UNKNOWN: "Unknown"
  };
  return labels[reason] ?? reason;
}

export async function recordDeploymentFailure(
  deploymentId: string,
  projectId: string,
  options: {
    reason: DeploymentFailureReason;
    message: string;
    logs: string;
  }
): Promise<void> {
  const logs = options.logs.length <= LOG_TAIL ? options.logs : options.logs.slice(-LOG_TAIL);
  const failureMessage =
    options.message.length <= MESSAGE_MAX ? options.message : `${options.message.slice(0, MESSAGE_MAX)}…`;

  await prisma.deployment.update({
    where: { id: deploymentId },
    data: {
      status: DeploymentJobStatus.FAILED,
      logs,
      failureReason: options.reason,
      failureMessage
    }
  });
  await updateProject(projectId, {
    lastDeploymentStatus: "FAILED",
    deploymentLogs: logs
  });
}

export function clearDeploymentFailureFields(): {
  failureReason: null;
  failureMessage: null;
} {
  return { failureReason: null, failureMessage: null };
}
