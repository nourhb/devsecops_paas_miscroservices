import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import type { BuildBackend, BuildDeploymentBaseline, BuildProjectRecord, BuildTriggerResult, MonitorDeploymentArgs } from "@/server/build-backend";
import { prependBuildMetadata } from "@/server/build-metadata";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import type { ResolvedBuildPlan } from "@/server/build-planner";
import { env } from "@/server/config/env";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { IntegrationError } from "@/server/http/errors";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import { updateProject } from "@/server/projects/project-service";
import { promoteDeploymentAfterBuildSuccess } from "@/server/services/cluster-deploy-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
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
function mergeLogTail(existing: string, incoming: string): string {
    const base = existing.trimEnd();
    const chunk = incoming.trimEnd();
    if (!chunk) {
        return base.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    }
    if (!base) {
        return chunk.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    }
    if (base.endsWith(chunk)) {
        return base.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    }
    return `${base}\n${chunk}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
}
function artifactImageFromJenkinsLog(log: string, fallback: string): string {
    const matches = [...log.matchAll(/PAAS_ARTIFACT_IMAGE=([^\s]+)/g)];
    const value = matches.at(-1)?.[1]?.trim();
    return value || fallback;
}
function normalizeInitialBuildNumber(reported: number | null, baseline: number | null): number | null {
    if (reported === null) {
        return null;
    }
    if (baseline !== null && reported <= baseline) {
        return null;
    }
    return reported;
}
async function markDeploymentFailed(deploymentId: string, projectId: string, message: string, reason: DeploymentFailureReason = DeploymentFailureReason.UNKNOWN): Promise<void> {
    const tail = message.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    await recordDeploymentFailure(deploymentId, projectId, {
        reason,
        message,
        logs: tail
    });
}
const progressiveLogOffsets = new Map<string, number>();
export class JenkinsBuildBackend implements BuildBackend {
    readonly provider = "jenkins" as const;
    async provisionProjectIntegration(project: BuildProjectRecord): Promise<void> {
        await jenkinsClient.createPipeline(project.projectName);
    }
    async triggerBuild(project: BuildProjectRecord, plan: ResolvedBuildPlan): Promise<BuildTriggerResult> {
        const branch = project.branch?.trim() || env.DEPLOY_BRANCH_FALLBACK;
        const build = await jenkinsClient.triggerBuild(project.projectName, project.id, {
            branch,
            gitUrl: project.gitRepositoryUrl,
            gitCredentialsId: project.gitCredentialsId ?? null,
            imageName: buildDeployImageRepository(project.projectName),
            projectUuid: project.id
        });
        return {
            accepted: build.ok,
            provider: this.provider,
            runId: build.buildNumber === null ? null : String(build.buildNumber),
            runNumber: build.buildNumber,
            logs: prependBuildMetadata(build.buildLog, plan, { runId: build.buildNumber === null ? null : String(build.buildNumber), runNumber: build.buildNumber }),
            externalUrl: build.jobUrl ?? null,
            artifactImage: build.buildNumber === null ? null : `${buildDeployImageRepository(project.projectName)}:${build.buildNumber}`,
            artifactDigest: null
        };
    }
    async getDeploymentBaseline(project: BuildProjectRecord): Promise<BuildDeploymentBaseline> {
        const prior = await jenkinsClient.getLastBuildSummary(project.projectName, project.id, "deploy");
        return { runNumber: prior?.number ?? null };
    }
    async triggerDeployment(project: BuildProjectRecord, plan: ResolvedBuildPlan): Promise<BuildTriggerResult> {
        const branch = project.branch?.trim() || env.DEPLOY_BRANCH_FALLBACK;
        const build = await jenkinsClient.triggerDeployJob(project.projectName, project.id, {
            gitUrl: project.gitRepositoryUrl,
            branch,
            gitCredentialsId: project.gitCredentialsId ?? null,
            imageName: buildDeployImageRepository(project.projectName),
            projectUuid: project.id
        });
        return {
            accepted: build.ok,
            provider: this.provider,
            runId: build.buildNumber === null ? null : String(build.buildNumber),
            runNumber: build.buildNumber,
            logs: prependBuildMetadata(build.buildLog, plan, { runId: build.buildNumber === null ? null : String(build.buildNumber), runNumber: build.buildNumber }),
            externalUrl: build.jobUrl ?? null,
            artifactImage: build.buildNumber === null ? null : `${buildDeployImageRepository(project.projectName)}:${build.buildNumber}`,
            artifactDigest: null
        };
    }
    async monitorDeployment(args: MonitorDeploymentArgs): Promise<void> {
        const deployment = await prisma.deployment.findUnique({
            where: { id: args.deploymentId },
            include: { project: true }
        });
        if (!deployment) {
            return;
        }
        const { projectName, id: projectId } = deployment.project;
        const baseline = args.baseline.runNumber ?? deployment.priorJenkinsBuildNumber ?? null;
        const interval = env.JENKINS_DEPLOY_POLL_INTERVAL_MS;
        const deadline = Date.now() + env.JENKINS_DEPLOY_POLL_MAX_MS;
        let logTail = (deployment.logs ?? "").slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
        if (allowSimulation() || !jenkinsConfigured()) {
            if (allowSimulation()) {
                const simBuild = args.startedRun.runNumber ?? deployment.jenkinsBuildNumber ?? 1;
                const simLog = (deployment.logs && deployment.logs.trim()) ||
                    prependBuildMetadata("[simulation] Build backend polling skipped (DEVSECOPS_ALLOW_SIMULATION=true).", args.plan, {
                        runId: String(simBuild),
                        runNumber: simBuild,
                        artifactImage: `${buildDeployImageRepository(projectName)}:${simBuild}`
                    });
                await prisma.deployment.update({
                    where: { id: args.deploymentId },
                    data: {
                        jenkinsBuildNumber: simBuild,
                        logs: simLog.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
                    }
                });
                try {
                    await promoteDeploymentAfterBuildSuccess(args.deploymentId, projectId, projectName, {
                        provider: this.provider,
                        runId: String(simBuild),
                        runNumber: simBuild,
                        artifactImage: `${buildDeployImageRepository(projectName)}:${simBuild}`,
                        artifactDigest: null,
                        buildLogTail: simLog
                    });
                }
                catch (error) {
                    const msg = error instanceof Error ? error.message : String(error);
                    await markDeploymentFailed(args.deploymentId, projectId, `[post-build] ${msg}`, DeploymentFailureReason.UNKNOWN);
                }
                return;
            }
            const msg = "Jenkins is not configured on this server (missing JENKINS_URL, JENKINS_USER, or JENKINS_TOKEN). " +
                "Set those variables or enable simulation for local demos.";
            await markDeploymentFailed(args.deploymentId, projectId, msg, DeploymentFailureReason.TRIGGER);
            return;
        }
        let buildNum = normalizeInitialBuildNumber(args.startedRun.runNumber, baseline);
        try {
            while (buildNum === null && Date.now() < deadline) {
                const summary = await jenkinsClient.getLastBuildSummary(projectName, projectId, "deploy");
                if (summary && (baseline === null || summary.number > baseline)) {
                    buildNum = summary.number;
                }
                if (buildNum === null) {
                    await sleep(interval);
                }
            }
            if (buildNum === null) {
                await markDeploymentFailed(args.deploymentId, projectId, "Timed out waiting for the build backend to expose a new deployment run.", DeploymentFailureReason.TIMEOUT);
                return;
            }
            logTail = mergeLogTail(logTail, `[build] Monitoring ${this.provider} run #${buildNum}`);
            await prisma.deployment.update({
                where: { id: args.deploymentId },
                data: {
                    jenkinsBuildNumber: buildNum,
                    status: DeploymentJobStatus.DEPLOYING,
                    logs: logTail,
                    ...clearDeploymentFailureFields()
                }
            });
            while (Date.now() < deadline) {
                const currentOffset = progressiveLogOffsets.get(args.deploymentId) ?? 0;
                const progressive = await jenkinsClient.getBuildConsoleProgressiveText(projectName, projectId, buildNum, currentOffset, "deploy");
                if (progressive) {
                    progressiveLogOffsets.set(args.deploymentId, progressive.nextStart);
                    logTail = mergeLogTail(logTail, progressive.text);
                }
                const meta = await jenkinsClient.getBuildApiJson(projectName, projectId, buildNum, "deploy");
                if (!meta) {
                    logTail = mergeLogTail(logTail, "[build-monitor] Waiting for Jenkins metadata. Log streaming may continue while the upstream API is slow.");
                    await prisma.deployment.update({
                        where: { id: args.deploymentId },
                        data: {
                            status: DeploymentJobStatus.DEPLOYING,
                            logs: logTail,
                            ...clearDeploymentFailureFields()
                        }
                    });
                    await sleep(interval);
                    continue;
                }
                if (terminalResult(meta.result, meta.building)) {
                    if (meta.result === "SUCCESS") {
                        try {
                            const artifactImage = artifactImageFromJenkinsLog(logTail, `${buildDeployImageRepository(projectName)}:${buildNum}`);
                            await promoteDeploymentAfterBuildSuccess(args.deploymentId, projectId, projectName, {
                                provider: this.provider,
                                runId: String(buildNum),
                                runNumber: buildNum,
                                artifactImage,
                                artifactDigest: null,
                                buildLogTail: logTail
                            });
                        }
                        catch (error) {
                            const msg = error instanceof Error ? error.message : String(error);
                            await markDeploymentFailed(args.deploymentId, projectId, `[post-build] ${msg}`, DeploymentFailureReason.UNKNOWN);
                        }
                        return;
                    }
                    const backendMsg = `Build backend finished with result: ${meta.result ?? "UNKNOWN"}`;
                    await recordDeploymentFailure(args.deploymentId, projectId, {
                        reason: DeploymentFailureReason.JENKINS,
                        message: backendMsg,
                        logs: mergeLogTail(logTail, backendMsg)
                    });
                    return;
                }
                await prisma.deployment.update({
                    where: { id: args.deploymentId },
                    data: {
                        status: statusFromJenkins(meta.result, meta.building) === DeploymentJobStatus.PENDING
                            ? DeploymentJobStatus.DEPLOYING
                            : statusFromJenkins(meta.result, meta.building),
                        logs: logTail,
                        ...clearDeploymentFailureFields()
                    }
                });
                await updateProject(projectId, {
                    lastDeploymentStatus: "DEPLOYING",
                    buildStatus: "BUILDING",
                    deploymentLogs: logTail
                });
                await sleep(interval);
            }
            await markDeploymentFailed(args.deploymentId, projectId, `Timed out after ${env.JENKINS_DEPLOY_POLL_MAX_MS}ms while polling ${this.provider} run #${buildNum}.`, DeploymentFailureReason.TIMEOUT);
        }
        catch (error) {
            if (error instanceof IntegrationError) {
                await markDeploymentFailed(args.deploymentId, projectId, error.details || error.message, DeploymentFailureReason.UNKNOWN);
                return;
            }
            throw error;
        }
        finally {
            progressiveLogOffsets.delete(args.deploymentId);
        }
    }
}
