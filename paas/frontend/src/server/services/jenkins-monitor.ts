import { DeploymentFailureReason } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { getBuildBackend, toBuildProjectRecord } from "@/server/build-backend";
import { resolveBuildPlan } from "@/server/build-planner";
import { recordDeploymentFailure } from "@/server/services/deployment-failure";
const activeMonitors = new Set<string>();
export function monitorDeployment(deploymentId: string, initialBuildNumber: number | null): void {
    if (activeMonitors.has(deploymentId)) {
        return;
    }
    activeMonitors.add(deploymentId);
    void runMonitorLoop(deploymentId, initialBuildNumber).catch((e) => {
        const message = e instanceof Error ? e.message : String(e);
        void (async () => {
            const row = await prisma.deployment.findUnique({ where: { id: deploymentId } });
            if (row) {
                await recordDeploymentFailure(deploymentId, row.projectId, {
                    reason: DeploymentFailureReason.UNKNOWN,
                    message: `[build-monitor] ${message}`,
                    logs: `[build-monitor] ${message}`
                });
            }
        })();
    }).finally(() => {
        activeMonitors.delete(deploymentId);
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
