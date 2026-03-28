import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { buildAppPublicUrl } from "@/server/deploy/app-public-url";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { commitHelmValuesGitHub } from "@/server/gitops/gitops-github-service";
import { updateProject } from "@/server/projects/project-service";
import { syncArgoApplication } from "@/server/services/argocd-service";
import {
  clearDeploymentFailureFields,
  recordDeploymentFailure
} from "@/server/services/deployment-failure";

const LOG_MAX = 5000;

function tail(s: string): string {
  return s.length <= LOG_MAX ? s : s.slice(-LOG_MAX);
}

async function persistFailure(
  deploymentId: string,
  projectId: string,
  fullLog: string,
  reason: DeploymentFailureReason,
  shortMessage: string
): Promise<void> {
  const logs = tail(fullLog);
  await recordDeploymentFailure(deploymentId, projectId, {
    reason,
    message: shortMessage,
    logs
  });
}

/**
 * After Jenkins reports SUCCESS: record that milestone, bump Helm image tag in GitOps, then trigger Argo CD sync.
 * Status sequence: SUCCESS → DEPLOYING → DEPLOYED (or FAILED on GitOps/Argo error).
 */
export async function promoteDeploymentAfterJenkinsSuccess(
  deploymentId: string,
  projectId: string,
  projectName: string,
  jenkinsBuildNumber: number,
  jenkinsLogTail: string
): Promise<void> {
  let imageRef: string;
  try {
    imageRef = `${buildDeployImageRepository(projectName)}:${jenkinsBuildNumber}`;
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    await persistFailure(
      deploymentId,
      projectId,
      `${jenkinsLogTail}\n\n[deploy] Could not build image reference: ${msg}`,
      DeploymentFailureReason.IMAGE_REF,
      msg
    );
    return;
  }

  const jenkinsPart = tail(jenkinsLogTail);

  await prisma.deployment.update({
    where: { id: deploymentId },
    data: { status: DeploymentJobStatus.SUCCESS, logs: jenkinsPart, ...clearDeploymentFailureFields() }
  });
  await updateProject(projectId, {
    lastDeploymentStatus: "SUCCESS",
    deploymentLogs: jenkinsPart
  });

  await prisma.deployment.update({
    where: { id: deploymentId },
    data: { status: DeploymentJobStatus.DEPLOYING, ...clearDeploymentFailureFields() }
  });
  await updateProject(projectId, { lastDeploymentStatus: "DEPLOYING" });
  const sections: string[] = [
    jenkinsLogTail,
    "",
    "--- GitOps (Helm values) + Argo CD ---",
    `[image] ${imageRef}`
  ];

  try {
    const git = await commitHelmValuesGitHub(projectName, imageRef);
    sections.push(`[gitops] committed ${git.ref}`);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    sections.push(`[gitops] FAILED: ${msg}`);
    await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.GITOPS, msg);
    return;
  }

  try {
    const argo = await syncArgoApplication(projectName);
    sections.push(argo.logs);
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e);
    sections.push(`[argocd] FAILED: ${msg}`);
    await persistFailure(deploymentId, projectId, sections.join("\n"), DeploymentFailureReason.ARGOCD, msg);
    return;
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
    deploymentLogs: okLog,
    imageTag: imageRef,
    url: appUrl
  });
}
