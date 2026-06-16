import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import type { BuildBackend, BuildDeploymentBaseline, BuildProjectRecord, BuildTriggerOptions, BuildTriggerResult, MonitorDeploymentArgs } from "@/server/build/build-backend";
import { prependBuildMetadata } from "@/server/build/build-metadata";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import type { ResolvedBuildPlan } from "@/server/build/build-planner";
import { env } from "@/server/config/env";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { IntegrationError } from "@/server/http/errors";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { jenkinsClient, resolveJenkinsJobNameForProject, usesSharedJenkinsDeployJob } from "@/server/integrations/devsecops-clients";
import { jenkinsResultUserMessage } from "@/server/jenkins/jenkins-result-user-message";
import { resolveVerifiedArtifactImage, pickJenkinsLogForArtifactVerify } from "@/server/jenkins/jenkins-build-artifact";
import { syncInlinePaasDeployJenkinsJobBeforeTrigger } from "@/server/jenkins/sync-inline-pipeline-job";
import { buildEnvJenkinsTriggerLog } from "@/server/projects/project-secrets-crypto";
import { updateProject } from "@/server/projects/project-service";
import { promoteDeploymentAfterBuildSuccess, tryCompleteDeploymentIfLive } from "@/server/services/cluster-deploy-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
import { extractJenkinsRunFromLogs } from "@/server/services/jenkins-deployment-reconcile";
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
async function drainProgressiveLogTail(projectName: string, projectId: string, buildNum: number, deploymentId: string, existing: string): Promise<string> {
    let tail = existing;
    let offset = progressiveLogOffsets.get(deploymentId) ?? 0;
    for (let i = 0; i < 40; i++) {
        const chunk = await jenkinsClient.getBuildConsoleProgressiveText(projectName, projectId, buildNum, offset, "deploy");
        if (!chunk?.text) {
            break;
        }
        offset = chunk.nextStart;
        progressiveLogOffsets.set(deploymentId, offset);
        tail = mergeLogTail(tail, chunk.text);
        if (!chunk.moreData) {
            break;
        }
    }
    return tail;
}
async function jenkinsLogForArtifactVerify(projectName: string, projectId: string, buildNum: number, deploymentId: string, progressiveTail: string): Promise<string> {
    let tail = await drainProgressiveLogTail(projectName, projectId, buildNum, deploymentId, progressiveTail);
    if (/PAAS_BUILD_COMPLETE\s+result=/i.test(tail)) {
        return tail;
    }
    const full = await jenkinsClient.getBuildConsoleText(projectName, projectId, buildNum, "deploy");
    return pickJenkinsLogForArtifactVerify(tail, full);
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
    async triggerBuild(project: BuildProjectRecord, plan: ResolvedBuildPlan, options?: BuildTriggerOptions): Promise<BuildTriggerResult> {
        const branch = (options?.branchOverride?.trim() || project.branch?.trim() || env.DEPLOY_BRANCH_FALLBACK);
        const gitCredentialsId = options?.gitCredentialsIdOverride !== undefined
            ? options.gitCredentialsIdOverride
            : project.gitCredentialsId ?? null;
        const jobName = resolveJenkinsJobNameForProject(project.projectName, project.id, "build");
        const syncLog = await syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName);
        const buildEnvLog = buildEnvJenkinsTriggerLog(project.buildEnvStored, project.buildEnv);
        const build = await jenkinsClient.triggerBuild(project.projectName, project.id, {
            branch,
            gitUrl: project.gitRepositoryUrl,
            gitCredentialsId: gitCredentialsId ? String(gitCredentialsId).trim() || null : null,
            imageName: buildDeployImageRepository(project.projectName),
            projectUuid: project.id,
            buildEnv: project.buildEnv ?? null
        });
        return {
            accepted: build.ok,
            provider: this.provider,
            runId: build.buildNumber === null ? null : String(build.buildNumber),
            runNumber: build.buildNumber,
            logs: prependBuildMetadata(`${buildEnvLog}\n${syncLog}\n\n${build.buildLog}`, plan, { runId: build.buildNumber === null ? null : String(build.buildNumber), runNumber: build.buildNumber }),
            externalUrl: build.jobUrl ?? null,
            artifactImage: build.buildNumber === null ? null : `${buildDeployImageRepository(project.projectName)}:${build.buildNumber}`,
            artifactDigest: null
        };
    }
    async getDeploymentBaseline(project: BuildProjectRecord): Promise<BuildDeploymentBaseline> {
        const prior = await jenkinsClient.getLastBuildSummary(project.projectName, project.id, "deploy");
        return { runNumber: prior?.number ?? null };
    }
    async triggerDeployment(project: BuildProjectRecord, plan: ResolvedBuildPlan, options?: BuildTriggerOptions): Promise<BuildTriggerResult> {
        const branch = (options?.branchOverride?.trim() || project.branch?.trim() || env.DEPLOY_BRANCH_FALLBACK);
        const gitCredentialsId = options?.gitCredentialsIdOverride !== undefined
            ? options.gitCredentialsIdOverride
            : project.gitCredentialsId ?? null;
        const jobName = resolveJenkinsJobNameForProject(project.projectName, project.id, "deploy");
        const syncLog = await syncInlinePaasDeployJenkinsJobBeforeTrigger(jobName);
        const buildEnvLog = buildEnvJenkinsTriggerLog(project.buildEnvStored, project.buildEnv);
        const build = await jenkinsClient.triggerDeployJob(project.projectName, project.id, {
            gitUrl: project.gitRepositoryUrl,
            branch,
            gitCredentialsId: gitCredentialsId ? String(gitCredentialsId).trim() || null : null,
            imageName: buildDeployImageRepository(project.projectName),
            projectUuid: project.id,
            buildEnv: project.buildEnv ?? null
        });
        return {
            accepted: build.ok,
            provider: this.provider,
            runId: build.buildNumber === null ? null : String(build.buildNumber),
            runNumber: build.buildNumber,
            logs: prependBuildMetadata(`${buildEnvLog}\n${syncLog}\n\n${build.buildLog}`, plan, { runId: build.buildNumber === null ? null : String(build.buildNumber), runNumber: build.buildNumber }),
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
        const resolveDeadline = Date.now() + env.PAAS_JENKINS_BUILD_RESOLVE_MAX_MS;
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
        if (buildNum != null && !(await jenkinsClient.verifyDeployBuildBelongsToProject(projectName, projectId, buildNum))) {
            buildNum = null;
        }
        try {
            let waitTicks = 0;
            while (buildNum === null && Date.now() < deadline) {
                const fromLogs = extractJenkinsRunFromLogs(deployment.logs);
                if (fromLogs != null && (baseline === null || fromLogs > baseline)) {
                    if (await jenkinsClient.verifyDeployBuildBelongsToProject(projectName, projectId, fromLogs)) {
                        buildNum = fromLogs;
                    }
                }
                if (buildNum === null) {
                    buildNum = await jenkinsClient.findDeployBuildForProject(projectName, projectId, {
                        baseline,
                        afterMs: deployment.createdAt.getTime() - 120_000,
                        limit: 50
                    });
                }
                if (buildNum === null && !usesSharedJenkinsDeployJob()) {
                    const summary = await jenkinsClient.getLastBuildSummary(projectName, projectId, "deploy");
                    if (summary && (baseline === null || summary.number > baseline)) {
                        buildNum = summary.number;
                    }
                }
                if (buildNum === null) {
                    waitTicks++;
                    if (waitTicks === 1 || waitTicks % 6 === 0) {
                        logTail = mergeLogTail(logTail, "[build] Waiting for Jenkins run for this project on shared paas-deploy…");
                        await prisma.deployment.update({
                            where: { id: args.deploymentId },
                            data: {
                                status: DeploymentJobStatus.PENDING,
                                jenkinsBuildNumber: null,
                                logs: logTail,
                                ...clearDeploymentFailureFields()
                            }
                        });
                    }
                    if (Date.now() > resolveDeadline) {
                        await markDeploymentFailed(args.deploymentId, projectId, "No Jenkins build matched this project within 15 minutes. Cancel this deployment, wait until the Jenkins queue is idle, then deploy this project alone.", DeploymentFailureReason.TIMEOUT);
                        return;
                    }
                    await sleep(interval);
                }
            }
            if (buildNum === null) {
                await markDeploymentFailed(args.deploymentId, projectId, "Timed out waiting for the build backend to expose a new deployment run.", DeploymentFailureReason.TIMEOUT);
                return;
            }
            let activeBuildNum: number = buildNum;
            let monitorTicks = 0;
            logTail = mergeLogTail(logTail, `[build] Monitoring ${this.provider} run #${activeBuildNum}`);
            await prisma.deployment.update({
                where: { id: args.deploymentId },
                data: {
                    jenkinsBuildNumber: activeBuildNum,
                    status: DeploymentJobStatus.DEPLOYING,
                    logs: logTail,
                    ...clearDeploymentFailureFields()
                }
            });
            while (Date.now() < deadline) {
                monitorTicks++;
                if (usesSharedJenkinsDeployJob() && monitorTicks % 6 === 0) {
                    if (!(await jenkinsClient.verifyDeployBuildBelongsToProject(projectName, projectId, activeBuildNum))) {
                        const reassigned = await jenkinsClient.findDeployBuildForProject(projectName, projectId, {
                            baseline,
                            afterMs: deployment.createdAt.getTime() - 120_000,
                            limit: 50
                        });
                        if (reassigned != null && reassigned !== activeBuildNum) {
                            activeBuildNum = reassigned;
                            progressiveLogOffsets.set(args.deploymentId, 0);
                            logTail = mergeLogTail(logTail, `[build] Switched monitor to Jenkins run #${activeBuildNum} for this project.`);
                            await prisma.deployment.update({
                                where: { id: args.deploymentId },
                                data: { jenkinsBuildNumber: activeBuildNum, logs: logTail, ...clearDeploymentFailureFields() }
                            });
                        }
                    }
                }
                const currentOffset = progressiveLogOffsets.get(args.deploymentId) ?? 0;
                const progressive = await jenkinsClient.getBuildConsoleProgressiveText(projectName, projectId, activeBuildNum, currentOffset, "deploy");
                if (progressive) {
                    progressiveLogOffsets.set(args.deploymentId, progressive.nextStart);
                    logTail = mergeLogTail(logTail, progressive.text);
                }
                const meta = await jenkinsClient.getBuildApiJson(projectName, projectId, activeBuildNum, "deploy");
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
                        await updateProject(projectId, {
                            buildStatus: "SUCCESS",
                            lastDeploymentStatus: "SUCCESS",
                            deploymentLogs: logTail
                        });
                        if (!(await jenkinsClient.verifyDeployBuildBelongsToProject(projectName, projectId, activeBuildNum))) {
                            const reassigned = await jenkinsClient.findDeployBuildForProject(projectName, projectId, {
                                baseline,
                                afterMs: deployment.createdAt.getTime() - 120_000
                            });
                            if (reassigned === null) {
                                await sleep(interval);
                                continue;
                            }
                            activeBuildNum = reassigned;
                            progressiveLogOffsets.set(args.deploymentId, 0);
                            logTail = mergeLogTail(logTail, `[build] Reassigned monitor to Jenkins run #${activeBuildNum} (prior run belonged to another project).`);
                            await prisma.deployment.update({
                                where: { id: args.deploymentId },
                                data: { jenkinsBuildNumber: activeBuildNum, logs: logTail, ...clearDeploymentFailureFields() }
                            });
                            continue;
                        }
                        const verifyLog = await jenkinsLogForArtifactVerify(projectName, projectId, activeBuildNum, args.deploymentId, logTail);
                        const completeLine = verifyLog.match(/PAAS_BUILD_COMPLETE[^\n]*/i)?.[0]?.trim();
                        if (completeLine) {
                            logTail = mergeLogTail(logTail, completeLine);
                        }
                        const verified = resolveVerifiedArtifactImage(verifyLog, projectId, projectName, activeBuildNum);
                        if (!verified.image) {
                            await markDeploymentFailed(args.deploymentId, projectId, verified.error ?? `Could not verify Jenkins artifact for build #${activeBuildNum}.`, DeploymentFailureReason.JENKINS);
                            return;
                        }
                        try {
                            if (await tryCompleteDeploymentIfLive(args.deploymentId)) {
                                return;
                            }
                            await promoteDeploymentAfterBuildSuccess(args.deploymentId, projectId, projectName, {
                                provider: this.provider,
                                runId: String(activeBuildNum),
                                runNumber: activeBuildNum,
                                artifactImage: verified.image,
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
                    const backendMsg = jenkinsResultUserMessage(meta.result, logTail);
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
