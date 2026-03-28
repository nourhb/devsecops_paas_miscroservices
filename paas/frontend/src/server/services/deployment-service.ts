import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { IntegrationError, NotFoundError } from "@/server/http/errors";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import {
  assertProjectAccess,
  getProjectById,
  updateProject
} from "@/server/projects/project-service";
import {
  clearDeploymentFailureFields,
  recordDeploymentFailure
} from "@/server/services/deployment-failure";
import { monitorDeployment } from "@/server/services/jenkins-monitor";
import type { ActionResponse, UserRole } from "@/types";

function effectiveTriggerUserId(jwtUserId: string): string | null {
  const override = env.DEPLOYMENT_TRIGGER_USER_ID.trim();
  if (override) {
    return override;
  }
  return jwtUserId;
}

export interface DeploymentStatusPayload {
  id: string;
  projectId: string;
  status: DeploymentJobStatus;
  logs: string;
  buildNumber: number | null;
  url: string | null;
  failureReason: string | null;
  failureMessage: string | null;
}

export interface DeploymentListItem {
  id: string;
  status: DeploymentJobStatus;
  createdAt: string;
  buildNumber: number | null;
  url: string | null;
  failureReason: string | null;
  failureMessage: string | null;
}

export async function listDeploymentsForProject(
  projectId: string,
  userId: string,
  role: UserRole
): Promise<DeploymentListItem[]> {
  await assertProjectAccess(projectId, userId, role);
  const rows = await prisma.deployment.findMany({
    where: { projectId },
    orderBy: { createdAt: "desc" },
    take: 50,
    select: {
      id: true,
      status: true,
      createdAt: true,
      jenkinsBuildNumber: true,
      url: true,
      failureReason: true,
      failureMessage: true
    }
  });
  return rows.map((r) => ({
    id: r.id,
    status: r.status,
    createdAt: r.createdAt.toISOString(),
    buildNumber: r.jenkinsBuildNumber,
    url: r.url,
    failureReason: r.failureReason,
    failureMessage: r.failureMessage
  }));
}

/**
 * Creates a Deployment row, triggers Jenkins with GIT_URL / BRANCH / IMAGE_NAME / PROJECT_ID,
 * then returns immediately while {@link monitorDeployment} polls Jenkins in the background.
 */
export async function runProjectDeployment(projectId: string, jwtUserId: string): Promise<ActionResponse> {
  const project = await getProjectById(projectId);
  const triggeredById = effectiveTriggerUserId(jwtUserId);

  const prior = await jenkinsClient.getLastBuildSummary(project.projectName, project.id);

  const deployment = await prisma.deployment.create({
    data: {
      projectId,
      status: DeploymentJobStatus.PENDING,
      logs: "",
      priorJenkinsBuildNumber: prior?.number ?? null,
      ...(triggeredById ? { triggeredById } : {})
    }
  });

  const branch = project.branch?.trim() || env.DEPLOY_BRANCH_FALLBACK;
  const imageName = buildDeployImageRepository(project.projectName);

  let build;
  try {
    build = await jenkinsClient.triggerDeployJob(project.projectName, project.id, {
      gitUrl: project.gitRepositoryUrl,
      branch,
      imageName,
      projectUuid: project.id
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await recordDeploymentFailure(deployment.id, project.id, {
      reason: DeploymentFailureReason.TRIGGER,
      message,
      logs: message
    });
    throw e;
  }

  if (!build.ok) {
    const msg = "Jenkins rejected the deploy trigger (HTTP error). See logs for the response body.";
    await recordDeploymentFailure(deployment.id, project.id, {
      reason: DeploymentFailureReason.TRIGGER,
      message: msg,
      logs: build.buildLog
    });
    throw new IntegrationError("Jenkins did not accept the deploy trigger — check job parameters and folder.");
  }

  const initialLog = build.buildLog.slice(-5000);
  await prisma.deployment.update({
    where: { id: deployment.id },
    data: {
      status: DeploymentJobStatus.PENDING,
      logs: initialLog,
      jenkinsBuildNumber: build.buildNumber,
      ...clearDeploymentFailureFields()
    }
  });

  await updateProject(project.id, {
    lastDeploymentStatus: "PENDING",
    deploymentLogs: initialLog
  });

  monitorDeployment(deployment.id, build.buildNumber);

  return {
    status: "SUCCESS",
    message: `Deployment queued for ${project.projectName}. Poll GET /api/deployments/${deployment.id} for live status.`,
    deploymentLogUrl: build.jobUrl ?? `jenkins://job/${project.projectName}/lastBuild/console`,
    deploymentId: deployment.id
  };
}

export async function getDeploymentForUser(
  deploymentId: string,
  userId: string,
  role: UserRole
): Promise<DeploymentStatusPayload> {
  const row = await prisma.deployment.findUnique({
    where: { id: deploymentId },
    include: { project: true }
  });
  if (!row) {
    throw new NotFoundError("Deployment not found");
  }
  await assertProjectAccess(row.projectId, userId, role);
  return {
    id: row.id,
    projectId: row.projectId,
    status: row.status,
    logs: row.logs ?? "",
    buildNumber: row.jenkinsBuildNumber,
    url: row.url,
    failureReason: row.failureReason,
    failureMessage: row.failureMessage
  };
}
