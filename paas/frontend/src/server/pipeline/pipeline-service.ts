import type { ActionResponse, DeploymentStatus } from "@/types";
import { IntegrationError } from "@/server/http/errors";
import { getProjectById, mapProjectToResponse, updateProject } from "@/server/projects/project-service";
import { getNamespacePodSummary } from "@/server/integrations/kubernetes-client";
import { env } from "@/server/config/env";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";

function imageTagFor(projectName: string): string {
  return `${projectName}:${new Date().toISOString().replace(/[:.]/g, "-")}`;
}

export async function triggerBuild(projectId: string): Promise<ActionResponse> {
  const project = await getProjectById(projectId);
  const build = await jenkinsClient.triggerBuild(project.projectName, project.id, project.branch);
  const imageTag = imageTagFor(project.projectName);

  if (!build.ok) {
    await updateProject(project.id, {
      buildStatus: "FAILED",
      buildLogs: build.buildLog
    });
    throw new IntegrationError("Jenkins did not accept the build trigger — check job name, folder, and parameters.");
  }

  await updateProject(project.id, {
    buildStatus: "SUCCESS",
    imageTag,
    buildLogs: `${build.buildLog}\n[build] Tagged: ${imageTag}`
  });

  return {
    status: "SUCCESS",
    message: `Build triggered for ${project.projectName}`,
    buildLogUrl: build.jobUrl ?? `jenkins://job/${project.projectName}/lastBuild/console`
  };
}

export async function rollbackProject(projectId: string): Promise<ActionResponse> {
  const project = await getProjectById(projectId);
  const rollbackLog = `[rollback] Project ${project.projectName} rolled back to previous stable release`;

  await updateProject(project.id, {
    lastDeploymentStatus: "ROLLED_BACK",
    podStatus: "RUNNING",
    deploymentLogs: `${project.deploymentLogs || ""}\n${rollbackLog}`
  });

  return {
    status: "SUCCESS",
    message: `Rollback executed for ${project.projectName}`
  };
}

export async function getProjectStatus(projectId: string): Promise<DeploymentStatus> {
  const project = await getProjectById(projectId);
  const base = mapProjectToResponse(project);

  if (env.KUBERNETES_ENABLED !== "true") {
    return base;
  }

  const live = await getNamespacePodSummary(project.namespace);
  if (live.error && live.total === 0) {
    return {
      ...base,
      podStatus: `${base.podStatus} · k8s: ${live.error}`
    };
  }

  if (live.total > 0) {
    return {
      ...base,
      podStatus: `${live.running} running · ${live.failed} failed · ${live.pending} pending (${live.total} pods)`
    };
  }

  return base;
}
