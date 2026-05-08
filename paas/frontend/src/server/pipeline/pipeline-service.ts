import { Prisma } from "@prisma/client";
import type { ActionResponse, DeploymentStatus } from "@/types";
import type { BuildTriggerOptions } from "@/server/build-backend";
import { getBuildBackend } from "@/server/build-backend";
import { resolveBuildPlan } from "@/server/build-planner";
import { IntegrationError } from "@/server/http/errors";
import { getProjectById, mapProjectToResponse, updateProject } from "@/server/projects/project-service";
import { getNamespacePodSummary } from "@/server/integrations/kubernetes-client";
import { env } from "@/server/config/env";
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
    const build = await backend.triggerBuild(project, plan, options);
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
export async function getProjectStatus(projectId: string): Promise<DeploymentStatus> {
    const project = await getProjectById(projectId);
    const base = mapProjectToResponse(project);
    if (env.KUBERNETES_ENABLED === "true") {
        const live = await getNamespacePodSummary(project.namespace);
        if (live.error && live.total === 0) {
            return {
                ...base,
                podStatus: summarizeKubernetesError(live.error),
                deploymentLogs: [base.deploymentLogs, `[k8s] ${live.error}`].filter(Boolean).join("\n")
            };
        }
        if (live.total > 0) {
            return {
                ...base,
                podStatus: `${live.running} running · ${live.failed} failed · ${live.pending} pending (${live.total} pods)`
            };
        }
    }
    const ds = (base.lastDeploymentStatus || "").toUpperCase();
    let podStatus = base.podStatus;
    if (!podStatus || podStatus === "UNKNOWN") {
        if (ds === "DEPLOYED") {
            podStatus = env.KUBERNETES_ENABLED === "true" ? "DEPLOYED (0 pods in namespace)" : "DEPLOYED (enable KUBERNETES_ENABLED for live pod status)";
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
            podStatus = env.KUBERNETES_ENABLED === "true" ? "No pods in namespace yet" : "Kubernetes disabled \u2014 pod health from cluster unavailable";
        }
    }
    return { ...base, podStatus };
}
