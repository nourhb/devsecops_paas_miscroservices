import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import { promoteDeploymentAfterJenkinsSuccess } from "@/server/services/cluster-deploy-service";
import {
  clearDeploymentFailureFields,
  recordDeploymentFailure
} from "@/server/services/deployment-failure";

const CONSOLE_TAIL_CHARS = 5000;

function jenkinsConfigured(): boolean {
  return Boolean(env.JENKINS_BASE_URL && env.JENKINS_USERNAME && env.JENKINS_API_TOKEN);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function statusFromJenkins(result: string | null, building: boolean): DeploymentJobStatus {
  if (building || result === null) {
    return DeploymentJobStatus.PENDING;
  }
  if (result === "SUCCESS") {
    return DeploymentJobStatus.SUCCESS;
  }
  return DeploymentJobStatus.FAILED;
}

function terminalResult(result: string | null, building: boolean): boolean {
  return !building && result !== null;
}

function normalizeInitialBuildNumber(
  reported: number | null,
  baseline: number | null
): number | null {
  if (reported === null) {
    return null;
  }
  if (baseline !== null && reported <= baseline) {
    return null;
  }
  return reported;
}

async function markDeploymentFailed(
  deploymentId: string,
  projectId: string,
  message: string,
  reason: DeploymentFailureReason = DeploymentFailureReason.UNKNOWN
): Promise<void> {
  const tail = message.slice(-CONSOLE_TAIL_CHARS);
  await recordDeploymentFailure(deploymentId, projectId, {
    reason,
    message,
    logs: tail
  });
}

/**
 * Polls Jenkins for build `result` / `building` and console output every {@link env.JENKINS_DEPLOY_POLL_INTERVAL_MS}.
 * Does not block the caller — schedules an async loop via `void monitorDeployment(...)`.
 *
 * Steps:
 * 1. If Jenkins is not configured and simulation is allowed, mark SUCCESS and exit.
 * 2. Resolve the real build number (may differ from the trigger-time guess when it matches an older build).
 * 3. Loop until `result` is set (SUCCESS → SUCCESS, FAILURE/UNSTABLE/ABORTED → FAILED) or max wait exceeded.
 * 4. Persist last {@link CONSOLE_TAIL_CHARS} characters of consoleText into `Deployment.logs`.
 */
export function monitorDeployment(deploymentId: string, initialBuildNumber: number | null): void {
  void runMonitorLoop(deploymentId, initialBuildNumber).catch((e) => {
    const message = e instanceof Error ? e.message : String(e);
    void (async () => {
      const row = await prisma.deployment.findUnique({ where: { id: deploymentId } });
      if (row) {
        await markDeploymentFailed(
          deploymentId,
          row.projectId,
          `[jenkins-monitor] ${message}`,
          DeploymentFailureReason.UNKNOWN
        );
      }
    })();
  });
}

async function runMonitorLoop(deploymentId: string, initialBuildNumber: number | null): Promise<void> {
  const deployment = await prisma.deployment.findUnique({
    where: { id: deploymentId },
    include: { project: true }
  });
  if (!deployment) {
    return;
  }

  const { projectName, id: projectId } = deployment.project;
  const baseline = deployment.priorJenkinsBuildNumber ?? null;
  const interval = env.JENKINS_DEPLOY_POLL_INTERVAL_MS;
  const deadline = Date.now() + env.JENKINS_DEPLOY_POLL_MAX_MS;

  if (!jenkinsConfigured()) {
    if (allowSimulation()) {
      const simLog = "[simulation] Jenkins not configured — skipped live polling.";
      const simBuild = deployment.jenkinsBuildNumber ?? 1;
      await prisma.deployment.update({
        where: { id: deploymentId },
        data: { jenkinsBuildNumber: simBuild }
      });
      try {
        await promoteDeploymentAfterJenkinsSuccess(
          deploymentId,
          projectId,
          projectName,
          simBuild,
          simLog
        );
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e);
        await markDeploymentFailed(
          deploymentId,
          projectId,
          `[post-Jenkins] ${msg}`,
          DeploymentFailureReason.UNKNOWN
        );
      }
    }
    return;
  }

  let buildNum = normalizeInitialBuildNumber(initialBuildNumber, baseline);

  while (buildNum === null && Date.now() < deadline) {
    const summary = await jenkinsClient.getLastBuildSummary(projectName, projectId);
    if (summary) {
      if (baseline === null || summary.number > baseline) {
        buildNum = summary.number;
      }
    }
    if (buildNum === null) {
      await sleep(interval);
    }
  }

  if (buildNum === null) {
    await markDeploymentFailed(
      deploymentId,
      projectId,
      "Timed out waiting for Jenkins to expose a new build number for this deploy.",
      DeploymentFailureReason.TIMEOUT
    );
    return;
  }

  await prisma.deployment.update({
    where: { id: deploymentId },
    data: { jenkinsBuildNumber: buildNum }
  });

  while (Date.now() < deadline) {
    const meta = await jenkinsClient.getBuildApiJson(projectName, projectId, buildNum);
    const rawConsole = await jenkinsClient.getBuildConsoleText(projectName, projectId, buildNum);
    const logTail = rawConsole ? rawConsole.slice(-CONSOLE_TAIL_CHARS) : "";

    if (!meta) {
      await prisma.deployment.update({
        where: { id: deploymentId },
        data: { status: DeploymentJobStatus.PENDING, logs: logTail, ...clearDeploymentFailureFields() }
      });
      await sleep(interval);
      continue;
    }

    if (terminalResult(meta.result, meta.building)) {
      if (meta.result === "SUCCESS") {
        try {
          await promoteDeploymentAfterJenkinsSuccess(
            deploymentId,
            projectId,
            projectName,
            buildNum,
            logTail
          );
        } catch (e) {
          const msg = e instanceof Error ? e.message : String(e);
          await markDeploymentFailed(
            deploymentId,
            projectId,
            `[post-Jenkins] ${msg}`,
            DeploymentFailureReason.UNKNOWN
          );
        }
        return;
      }

      const jenkinsMsg = `Jenkins build finished with result: ${meta.result ?? "UNKNOWN"}`;
      await recordDeploymentFailure(deploymentId, projectId, {
        reason: DeploymentFailureReason.JENKINS,
        message: jenkinsMsg,
        logs: logTail || jenkinsMsg
      });
      return;
    }

    await prisma.deployment.update({
      where: { id: deploymentId },
      data: {
        status: statusFromJenkins(meta.result, meta.building),
        logs: logTail,
        ...clearDeploymentFailureFields()
      }
    });

    await sleep(interval);
  }

  await markDeploymentFailed(
    deploymentId,
    projectId,
    `Timed out after ${env.JENKINS_DEPLOY_POLL_MAX_MS}ms while polling Jenkins build #${buildNum}.`,
    DeploymentFailureReason.TIMEOUT
  );
}
