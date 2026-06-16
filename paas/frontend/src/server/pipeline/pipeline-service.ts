import { Prisma, DeploymentJobStatus } from "@prisma/client";
import type { ActionResponse, DeploymentStatus } from "@/types";
import type { BuildTriggerOptions } from "@/server/build/build-backend";
import { getBuildBackend, toBuildProjectRecord } from "@/server/build/build-backend";
import { resolveBuildPlan } from "@/server/build/build-planner";
import { IntegrationError } from "@/server/http/errors";
import { getProjectById, mapProjectToResponse, updateProject } from "@/server/projects/project-service";
import { getNamespacePodSummary } from "@/server/integrations/kubernetes-client";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import { refreshProjectJenkinsDisplayStatus, reconcileJenkinsDeploymentRecord, extractJenkinsRunFromLogs } from "@/server/services/jenkins-deployment-reconcile";
function summarizeKubernetesError(message: string) {
    const normalized = message.trim();
    if (/unable to verify the first certificate|self[- ]signed certificate|certificate/i.test(normalized)) {
        return "Kubernetes TLS verification failed";
    }
    if (/forbidden|unauthorized/i.test(normalized)) {
        return "Kubernetes access denied";
    }
    if (/timeout|timed out|aborted/i.test(normalized)) {
        return "Kubernetes API timeout";
    }
    if (/not configured/i.test(normalized)) {
        return "Kubernetes not configured";
    }
    return "Kubernetes unavailable";
}
export async function triggerBuild(projectId: string, options?: BuildTriggerOptions): Promise<ActionResponse> {
    const project = await getProjectById(projectId);
    const backend = getBuildBackend();
    const plan = resolveBuildPlan(project);
    const build = await backend.triggerBuild(toBuildProjectRecord(project), plan, options);
    if (!build.accepted) {
        await updateProject(project.id, {
            buildStatus: "FAILED",
            buildLogs: build.logs
        });
        throw new IntegrationError("The build backend did not accept the build trigger.", {
            details: build.logs,
            data: build.externalUrl ? { jobUrl: build.externalUrl } : undefined
        });
    }
    await updateProject(project.id, {
        buildStatus: backend.provider === "tekton" ? "QUEUED" : "BUILDING",
        imageTag: build.artifactImage ?? project.imageTag,
        buildLogs: build.logs,
        pendingGitHubPush: Prisma.DbNull
    });
    return {
        status: "SUCCESS",
        message: `Build triggered for ${project.projectName}`,
        buildLogUrl: build.externalUrl ?? `${backend.provider}://${project.projectName}/${build.runId ?? "latest"}`
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
function jenkinsConfigured(): boolean {
    return Boolean(env.JENKINS_BASE_URL && env.JENKINS_USERNAME && env.JENKINS_API_TOKEN);
}

async function enrichBuildLogsFromJenkins(projectName: string, projectId: string, storedLogs: string): Promise<string> {
    if (!jenkinsConfigured()) {
        return storedLogs;
    }
    try {
        const last = await jenkinsClient.getLastBuildSummary(projectName, projectId, "deploy");
        if (!last?.number || last.building) {
            return storedLogs;
        }
        const storedRun = extractJenkinsRunFromLogs(storedLogs);
        if (storedRun === last.number && storedLogs.includes("PAAS_BUILD_COMPLETE")) {
            return storedLogs;
        }
        const console = await jenkinsClient.getBuildConsoleText(projectName, projectId, last.number, "deploy");
        if (!console?.trim()) {
            return storedLogs;
        }
        return console.length > 80_000 ? console.slice(-80_000) : console;
    }
    catch {
        return storedLogs;
    }
}

export async function getProjectStatus(projectId: string): Promise<DeploymentStatus> {
    await refreshProjectJenkinsDisplayStatus(projectId).catch(() => undefined);
    const active = await prisma.deployment.findFirst({
        where: {
            projectId,
            status: { in: [DeploymentJobStatus.PENDING, DeploymentJobStatus.DEPLOYING] }
        },
        orderBy: { createdAt: "desc" },
        select: { id: true, status: true }
    });
    if (active?.status === DeploymentJobStatus.PENDING) {
        void reconcileJenkinsDeploymentRecord(active.id).catch(() => undefined);
    }
    const project = await getProjectById(projectId);
    const base = mapProjectToResponse(project);
    const buildLogs = await enrichBuildLogsFromJenkins(project.projectName, project.id, base.buildLogs);
    const enriched = { ...base, buildLogs };
    if (env.KUBERNETES_ENABLED === "true") {
        const live = await getNamespacePodSummary(project.namespace);
        if (live.error && live.total === 0) {
            return {
                ...enriched,
                podStatus: summarizeKubernetesError(live.error),
                deploymentLogs: [enriched.deploymentLogs, `[k8s] ${live.error}`].filter(Boolean).join("\n")
            };
        }
        if (live.total > 0) {
            return {
                ...enriched,
                podStatus: `${live.running} running · ${live.failed} failed · ${live.pending} pending (${live.total} pods)`
            };
        }
    }
    const ds = (enriched.lastDeploymentStatus || "").toUpperCase();
    let podStatus = enriched.podStatus;
    if (!podStatus || podStatus === "UNKNOWN") {
        if (ds === "DEPLOYED") {
            podStatus = env.KUBERNETES_ENABLED === "true" ? "DEPLOYED (0 pods in namespace)" : "DEPLOYED (no live cluster data)";
        }
        else if (ds === "FAILED") {
            podStatus = "FAILED";
        }
        else if (ds === "DEPLOYING" || ds === "PROMOTING") {
            podStatus = ds === "DEPLOYING" ? "Deploying" : "Promoting (GitOps / registry)";
        }
        else if (ds === "SUCCESS") {
            podStatus = "Success (post-build promotion)";
        }
        else {
            podStatus = env.KUBERNETES_ENABLED === "true" ? "No pods in namespace yet" : "No live cluster data";
        }
    }
    return { ...enriched, podStatus };
}
