import { DeploymentFailureReason, DeploymentJobStatus } from "@prisma/client";
import type { BuildBackend, BuildDeploymentBaseline, BuildProjectRecord, BuildTriggerOptions, BuildTriggerResult, MonitorDeploymentArgs } from "@/server/build-backend";
import { prependBuildMetadata } from "@/server/build-metadata";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import type { ResolvedBuildPlan } from "@/server/build-planner";
import { env } from "@/server/config/env";
import { buildDeployImageRepository } from "@/server/deploy/deploy-image";
import { IntegrationError } from "@/server/http/errors";
import { getCustomObjectsApi, isKubernetesConfigured, listPodsByLabel, readPodLog } from "@/server/integrations/kubernetes-client";
import { allowSimulation } from "@/server/integrations/integration-mode";
import { updateProject } from "@/server/projects/project-service";
import { promoteDeploymentAfterBuildSuccess } from "@/server/services/cluster-deploy-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
type TektonRunStatus = "queued" | "running" | "succeeded" | "failed";
function tail(value: string): string {
    return value.length <= DEPLOYMENT_LOG_TAIL_MAX_CHARS ? value : value.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
}
function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}
function safeName(value: string): string {
    return value
        .toLowerCase()
        .replace(/[^a-z0-9-]/g, "-")
        .replace(/-+/g, "-")
        .replace(/^-|-$/g, "")
        .slice(0, 40) || "app";
}
function tektonConfigured(): boolean {
    return isKubernetesConfigured() && getCustomObjectsApi() !== null;
}
function tektonPipelineNameFor(plan: ResolvedBuildPlan): string {
    if (plan.profile === "node") {
        return env.TEKTON_NODE_PIPELINE_NAME;
    }
    return env.TEKTON_DEFAULT_PIPELINE_NAME;
}
function buildArtifactImage(projectName: string, runId: string): string {
    return `${buildDeployImageRepository(projectName)}:${runId}`;
}
function summarizePipelineRunStatus(pipelineRun: any): {
    status: TektonRunStatus;
    message: string;
} {
    const conditions = pipelineRun?.status?.conditions;
    const succeeded = Array.isArray(conditions) ? conditions.find((condition) => condition?.type === "Succeeded") : null;
    if (!succeeded) {
        return { status: "queued", message: "PipelineRun created; waiting for Tekton status." };
    }
    if (succeeded.status === "True") {
        return { status: "succeeded", message: succeeded.message || "Tekton PipelineRun succeeded." };
    }
    if (succeeded.status === "False") {
        return { status: "failed", message: succeeded.message || succeeded.reason || "Tekton PipelineRun failed." };
    }
    return { status: "running", message: succeeded.message || succeeded.reason || "Tekton PipelineRun is running." };
}
async function readPipelineRunLogs(runId: string): Promise<string> {
    const pods = await listPodsByLabel(env.TEKTON_NAMESPACE, `tekton.dev/pipelineRun=${runId}`);
    if (!pods.length) {
        return "";
    }
    const chunks: string[] = [];
    for (const pod of pods) {
        const podName = pod.metadata?.name;
        if (!podName) {
            continue;
        }
        const log = await readPodLog(env.TEKTON_NAMESPACE, podName);
        if (log && !chunks.includes(log)) {
            chunks.push(`--- ${podName} ---\n${log.trim()}`);
        }
    }
    return tail(chunks.join("\n\n"));
}
async function markDeploymentFailed(deploymentId: string, projectId: string, message: string, logs: string): Promise<void> {
    await recordDeploymentFailure(deploymentId, projectId, {
        reason: DeploymentFailureReason.UNKNOWN,
        message,
        logs: tail(logs || message)
    });
}
export class TektonBuildBackend implements BuildBackend {
    readonly provider = "tekton" as const;
    async provisionProjectIntegration(_project: BuildProjectRecord, _plan: ResolvedBuildPlan): Promise<void> {
        if (!tektonConfigured() && !allowSimulation()) {
            throw new IntegrationError("Tekton is selected as the build backend but Kubernetes or the Tekton CRDs are not reachable from this server.");
        }
    }
    async triggerBuild(project: BuildProjectRecord, plan: ResolvedBuildPlan, options?: BuildTriggerOptions): Promise<BuildTriggerResult> {
        return this.createPipelineRun(project, plan, null, options);
    }
    async getDeploymentBaseline(_project: BuildProjectRecord): Promise<BuildDeploymentBaseline> {
        return { runNumber: null };
    }
    async triggerDeployment(project: BuildProjectRecord, plan: ResolvedBuildPlan, options?: BuildTriggerOptions): Promise<BuildTriggerResult> {
        return this.createPipelineRun(project, plan, `deploy-${Date.now()}`, options);
    }
    private async createPipelineRun(project: BuildProjectRecord, plan: ResolvedBuildPlan, deploymentId: string | null, options?: BuildTriggerOptions): Promise<BuildTriggerResult> {
        const syntheticRunId = `${safeName(project.projectName)}-${Date.now()}`;
        const artifactImage = buildArtifactImage(project.projectName, syntheticRunId);
        const gitRevision = (options?.branchOverride?.trim() || project.branch?.trim() || env.DEPLOY_BRANCH_FALLBACK);
        if (!tektonConfigured()) {
            if (!allowSimulation()) {
                throw new IntegrationError("Tekton build backend is not configured. Kubernetes cluster access and Tekton are required.");
            }
            return {
                accepted: true,
                provider: this.provider,
                runId: syntheticRunId,
                runNumber: null,
                logs: prependBuildMetadata("[tekton] Simulation mode enabled; no PipelineRun created.", plan, { runId: syntheticRunId, artifactImage }),
                artifactImage,
                artifactDigest: null,
                externalUrl: null
            };
        }
        const api = getCustomObjectsApi();
        if (!api) {
            throw new IntegrationError("Kubernetes custom objects API is unavailable for Tekton operations.");
        }
        const runName = syntheticRunId;
        const body = {
            apiVersion: `tekton.dev/${env.TEKTON_API_VERSION}`,
            kind: "PipelineRun",
            metadata: {
                name: runName,
                namespace: env.TEKTON_NAMESPACE,
                labels: {
                    "app.kubernetes.io/managed-by": "paas",
                    "app.kubernetes.io/part-of": "build-platform",
                    "paas.dev/project-id": project.id,
                    "paas.dev/project-name": safeName(project.projectName),
                    "paas.dev/build-profile": plan.profile
                }
            },
            spec: {
                pipelineRef: {
                    name: tektonPipelineNameFor(plan)
                },
                taskRunTemplate: {
                    serviceAccountName: env.TEKTON_SERVICE_ACCOUNT
                },
                params: [
                    { name: "git-url", value: project.gitRepositoryUrl },
                    { name: "git-revision", value: gitRevision },
                    { name: "image", value: artifactImage },
                    { name: "project-id", value: project.id },
                    { name: "project-name", value: project.projectName },
                    { name: "build-profile", value: plan.profile },
                    { name: "build-mode", value: plan.mode },
                    { name: "template-version", value: plan.templateVersion },
                    ...(deploymentId ? [{ name: "deployment-id", value: deploymentId }] : [])
                ]
            }
        };
        try {
            await api.createNamespacedCustomObject("tekton.dev", env.TEKTON_API_VERSION, env.TEKTON_NAMESPACE, "pipelineruns", body);
        }
        catch (error) {
            const message = error instanceof Error ? error.message : String(error);
            throw new IntegrationError(`Tekton PipelineRun creation failed: ${message}`);
        }
        return {
            accepted: true,
            provider: this.provider,
            runId: runName,
            runNumber: null,
            logs: prependBuildMetadata(`[tekton] Created PipelineRun ${runName} with template ${tektonPipelineNameFor(plan)}.`, plan, { runId: runName, artifactImage }),
            artifactImage,
            artifactDigest: null,
            externalUrl: null
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
        const runId = args.startedRun.runId;
        if (!runId) {
            await markDeploymentFailed(args.deploymentId, args.project.id, "Tekton run id was not recorded.", args.startedRun.logs);
            return;
        }
        const api = getCustomObjectsApi();
        if (!api) {
            await markDeploymentFailed(args.deploymentId, args.project.id, "Kubernetes custom objects API is unavailable while monitoring Tekton.", args.startedRun.logs);
            return;
        }
        let logTail = tail(deployment.logs ?? args.startedRun.logs);
        const deadline = Date.now() + env.TEKTON_POLL_MAX_MS;
        while (Date.now() < deadline) {
            try {
                const response: any = await api.getNamespacedCustomObject("tekton.dev", env.TEKTON_API_VERSION, env.TEKTON_NAMESPACE, "pipelineruns", runId);
                const run = response.body ?? response;
                const state = summarizePipelineRunStatus(run);
                const podLogs = await readPipelineRunLogs(runId);
                logTail = tail([
                    deployment.logs ?? "",
                    `[tekton] ${state.message}`,
                    podLogs
                ]
                    .filter(Boolean)
                    .join("\n\n"));
                await prisma.deployment.update({
                    where: { id: args.deploymentId },
                    data: {
                        status: state.status === "succeeded"
                            ? DeploymentJobStatus.SUCCESS
                            : state.status === "failed"
                                ? DeploymentJobStatus.FAILED
                                : DeploymentJobStatus.DEPLOYING,
                        logs: logTail,
                        ...clearDeploymentFailureFields()
                    }
                });
                await updateProject(args.project.id, {
                    lastDeploymentStatus: state.status === "succeeded"
                        ? "PROMOTING"
                        : state.status === "failed"
                            ? "FAILED"
                            : "BUILDING",
                    buildStatus: state.status === "succeeded"
                        ? "PUSHING"
                        : state.status === "failed"
                            ? "FAILED"
                            : "BUILDING",
                    deploymentLogs: logTail
                });
                if (state.status === "failed") {
                    await markDeploymentFailed(args.deploymentId, args.project.id, state.message, logTail);
                    return;
                }
                if (state.status === "succeeded") {
                    await promoteDeploymentAfterBuildSuccess(args.deploymentId, args.project.id, args.project.projectName, {
                        provider: this.provider,
                        runId,
                        runNumber: null,
                        artifactImage: args.startedRun.artifactImage ?? buildArtifactImage(args.project.projectName, runId),
                        artifactDigest: null,
                        buildLogTail: logTail
                    });
                    return;
                }
            }
            catch (error) {
                const message = error instanceof Error ? error.message : String(error);
                await markDeploymentFailed(args.deploymentId, args.project.id, `Tekton monitoring failed: ${message}`, logTail);
                return;
            }
            await sleep(env.TEKTON_POLL_INTERVAL_MS);
        }
        await markDeploymentFailed(args.deploymentId, args.project.id, `Timed out after ${env.TEKTON_POLL_MAX_MS}ms while polling Tekton PipelineRun ${runId}.`, logTail);
    }
}
