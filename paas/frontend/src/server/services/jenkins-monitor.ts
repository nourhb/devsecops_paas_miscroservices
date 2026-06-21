import { DeploymentFailureReason } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { isTransientDbError } from "@/server/db/prisma-retry";
import { getBuildBackend, toBuildProjectRecord } from "@/server/build/build-backend";
import { resolveBuildPlan } from "@/server/build/build-planner";
import { clearDeploymentFailureFields, isBuildMonitorPostgresOutageMessage, recordDeploymentFailure } from "@/server/services/deployment-failure";

const activeMonitors = new Set<string>();
const TRANSIENT_RETRY_MS = 5000;
const TRANSIENT_RETRY_MAX = 360;

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export function monitorDeployment(deploymentId: string, initialBuildNumber: number | null): void {
    if (activeMonitors.has(deploymentId)) {
        return;
    }
    activeMonitors.add(deploymentId);
    void runMonitorWithTransientRetry(deploymentId, initialBuildNumber).finally(() => {
        activeMonitors.delete(deploymentId);
    });
}

async function runMonitorWithTransientRetry(deploymentId: string, initialBuildNumber: number | null): Promise<void> {
    let transientAttempts = 0;
    while (true) {
        try {
            await runMonitorLoop(deploymentId, initialBuildNumber);
            return;
        }
        catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            if (isTransientDbError(error) || isBuildMonitorPostgresOutageMessage(message)) {
                transientAttempts++;
                if (transientAttempts >= TRANSIENT_RETRY_MAX) {
                    console.warn(`[build-monitor] Postgres still unavailable after ${transientAttempts} retries — stopping monitor for ${deploymentId} (Jenkins may continue; run lab.sh db-repair)`);
                    return;
                }
                console.warn(`[build-monitor] Postgres unavailable (attempt ${transientAttempts}/${TRANSIENT_RETRY_MAX}) — retry in ${TRANSIENT_RETRY_MS}ms`);
                await sleep(TRANSIENT_RETRY_MS);
                continue;
            }
            const row = await prisma.deployment.findUnique({ where: { id: deploymentId } }).catch(() => null);
            if (row) {
                await recordDeploymentFailure(deploymentId, row.projectId, {
                    reason: DeploymentFailureReason.UNKNOWN,
                    message: `[build-monitor] ${message}`,
                    logs: `[build-monitor] ${message}`
                });
            }
            return;
        }
    }
}

async function runMonitorLoop(deploymentId: string, initialBuildNumber: number | null): Promise<void> {
    const deployment = await prisma.deployment.findUnique({
        where: { id: deploymentId },
        include: { project: true }
    });
    if (!deployment) {
        return;
    }
    const backend = getBuildBackend();
    const plan = resolveBuildPlan(deployment.project);
    await backend.monitorDeployment({
        deploymentId,
        project: toBuildProjectRecord(deployment.project),
        plan,
        startedRun: {
            accepted: true,
            provider: backend.provider,
            runId: initialBuildNumber === null ? null : String(initialBuildNumber),
            runNumber: initialBuildNumber,
            logs: deployment.logs ?? "",
            artifactImage: null,
            artifactDigest: null,
            externalUrl: null
        },
        baseline: {
            runNumber: deployment.priorJenkinsBuildNumber ?? null
        }
    });
}
