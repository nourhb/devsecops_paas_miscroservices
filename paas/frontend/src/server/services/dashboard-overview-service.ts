import { DeploymentJobStatus, type Prisma } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { listClusterDeployments, listClusterPods, listClusterServices } from "@/server/integrations/kubernetes-client";
import { listPlatformArtifacts } from "@/server/artifacts/artifact-service";
import { getPlatformTooling } from "@/server/platform/platform-tooling";
import { cosignClient, dependencyTrackClient, trivyClient } from "@/server/integrations/devsecops-clients";
import type { ArtifactRecord, PlatformToolGroup, UserRole } from "@/types";
function accessibleProjectsWhere(userId: string, role: UserRole): Prisma.ProjectWhereInput {
    return role === "ADMIN" ? { deletedAt: null } : { createdById: userId, deletedAt: null };
}
export interface DashboardOverview {
    stats: {
        totalProjects: number;
        totalDeployments: number;
        successRatePercent: number | null;
        activeDeployments: number;
        failedDeployments: number;
        runningPods: number;
        unhealthyPods: number;
        liveTools: number;
        degradedTools: number;
    };
    cluster: {
        pods: number;
        runningPods: number;
        services: number;
        deployments: number;
        healthyDeployments: number;
    };
    security: {
        score: number;
        critical: number;
        high: number;
        unsignedImages: number;
        policyBlocked: number;
    };
    artifacts: ArtifactRecord[];
    platformTools: PlatformToolGroup[];
    projects: {
        id: string;
        projectName: string;
        buildStatus: string;
        lastDeploymentStatus: string;
        podStatus: string;
        imageTag: string | null;
        url: string | null;
        updatedAt: string;
    }[];
    failedDeployments: {
        id: string;
        projectId: string;
        projectName: string;
        status: DeploymentJobStatus;
        failureReason: string | null;
        failureMessage: string | null;
        createdAt: string;
    }[];
    recentDeployments: {
        id: string;
        projectId: string;
        projectName: string;
        status: DeploymentJobStatus;
        createdAt: string;
    }[];
}
const emptySeverity = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0
};
async function safeProjectSecurity(project: {
    projectName: string;
    imageTag: string | null;
}): Promise<{
    critical: number;
    high: number;
    unsigned: boolean;
}> {
    const imageRef = project.imageTag || project.projectName;
    const [trivyResult, dependencyTrackResult, cosignResult] = await Promise.allSettled([
        trivyClient.scan(imageRef),
        dependencyTrackClient.projectMetrics(project.projectName),
        project.imageTag ? cosignClient.isSigned(project.imageTag) : Promise.resolve(true)
    ]);
    const trivy = trivyResult.status === "fulfilled" ? trivyResult.value : emptySeverity;
    const dependencyTrack = dependencyTrackResult.status === "fulfilled" ? dependencyTrackResult.value.metrics : emptySeverity;
    const signed = cosignResult.status === "fulfilled" ? cosignResult.value : true;
    return {
        critical: trivy.critical + dependencyTrack.critical,
        high: trivy.high + dependencyTrack.high,
        unsigned: !signed
    };
}
export async function getDashboardOverview(userId: string, role: UserRole): Promise<DashboardOverview> {
    const projects = await prisma.project.findMany({
        where: accessibleProjectsWhere(userId, role),
        orderBy: { updatedAt: "desc" },
        select: {
            id: true,
            projectName: true,
            buildStatus: true,
            lastDeploymentStatus: true,
            podStatus: true,
            imageTag: true,
            url: true,
            updatedAt: true
        }
    });
    const projectIds = projects.map((p) => p.id);
    if (projectIds.length === 0) {
        return {
            stats: {
                totalProjects: 0,
                totalDeployments: 0,
                successRatePercent: null,
                activeDeployments: 0,
                failedDeployments: 0,
                runningPods: 0,
                unhealthyPods: 0,
                liveTools: 0,
                degradedTools: 0
            },
            cluster: {
                pods: 0,
                runningPods: 0,
                services: 0,
                deployments: 0,
                healthyDeployments: 0
            },
            security: {
                score: 100,
                critical: 0,
                high: 0,
                unsignedImages: 0,
                policyBlocked: 0
            },
            artifacts: [],
            platformTools: [],
            projects: [],
            failedDeployments: [],
            recentDeployments: []
        };
    }
    const totalProjects = projectIds.length;
    const succeededStatuses = [DeploymentJobStatus.SUCCESS, DeploymentJobStatus.DEPLOYED];
    const [totalDeployments, activeDeployments, succeededCount, failedCount, recent, failedRecent, pods, services, k8sDeployments, artifactsPayload, tooling] = await Promise.all([
        prisma.deployment.count({ where: { projectId: { in: projectIds } } }),
        prisma.deployment.count({
            where: {
                projectId: { in: projectIds },
                status: { in: [DeploymentJobStatus.PENDING, DeploymentJobStatus.DEPLOYING] }
            }
        }),
        prisma.deployment.count({
            where: { projectId: { in: projectIds }, status: { in: succeededStatuses } }
        }),
        prisma.deployment.count({
            where: { projectId: { in: projectIds }, status: DeploymentJobStatus.FAILED }
        }),
        prisma.deployment.findMany({
            where: { projectId: { in: projectIds } },
            orderBy: { createdAt: "desc" },
            take: 15,
            select: {
                id: true,
                projectId: true,
                status: true,
                createdAt: true,
                project: { select: { projectName: true } }
            }
        }),
        prisma.deployment.findMany({
            where: { projectId: { in: projectIds }, status: DeploymentJobStatus.FAILED },
            orderBy: { createdAt: "desc" },
            take: 8,
            select: {
                id: true,
                projectId: true,
                status: true,
                failureReason: true,
                failureMessage: true,
                createdAt: true,
                project: { select: { projectName: true } }
            }
        }),
        listClusterPods(),
        listClusterServices(),
        listClusterDeployments(),
        listPlatformArtifacts(),
        getPlatformTooling()
    ]);
    const terminal = succeededCount + failedCount;
    const successRatePercent = terminal === 0 ? null : Math.round((succeededCount / terminal) * 100);
    const liveTools = tooling.groups.flatMap((g) => g.items).filter((item) => item.tone === "success").length;
    const degradedTools = tooling.groups.flatMap((g) => g.items).filter((item) => item.tone === "warning" || item.tone === "danger").length;
    const runningPods = pods.items.filter((pod) => pod.status === "Running").length;
    const unhealthyPods = pods.items.filter((pod) => pod.health !== "Healthy" && pod.health !== "Succeeded").length;
    const healthyDeployments = k8sDeployments.items.filter((deployment) => deployment.ready === `${deployment.replicas}/${deployment.replicas}`).length;
    const securitySamples = await Promise.all(projects.slice(0, 10).map((project) => safeProjectSecurity(project)));
    const critical = securitySamples.reduce((total, row) => total + row.critical, 0);
    const high = securitySamples.reduce((total, row) => total + row.high, 0);
    const unsignedImages = securitySamples.filter((row) => row.unsigned).length;
    const policyBlocked = projects.filter((project) => project.lastDeploymentStatus === "FAILED" || project.podStatus === "FAILED").length;
    const securityPenalty = critical * 15 + high * 5 + unsignedImages * 8 + policyBlocked * 5;
    const securityScore = Math.max(0, Math.min(100, 100 - securityPenalty));
    return {
        stats: {
            totalProjects,
            totalDeployments,
            successRatePercent,
            activeDeployments,
            failedDeployments: failedCount,
            runningPods,
            unhealthyPods,
            liveTools,
            degradedTools
        },
        cluster: {
            pods: pods.items.length,
            runningPods,
            services: services.items.length,
            deployments: k8sDeployments.items.length,
            healthyDeployments
        },
        security: {
            score: securityScore,
            critical,
            high,
            unsignedImages,
            policyBlocked
        },
        artifacts: artifactsPayload.artifacts.slice(0, 8),
        platformTools: tooling.groups,
        projects: projects.slice(0, 10).map((project) => ({
            id: project.id,
            projectName: project.projectName,
            buildStatus: project.buildStatus,
            lastDeploymentStatus: project.lastDeploymentStatus,
            podStatus: project.podStatus,
            imageTag: project.imageTag || null,
            url: project.url || null,
            updatedAt: project.updatedAt.toISOString()
        })),
        failedDeployments: failedRecent.map((r) => ({
            id: r.id,
            projectId: r.projectId,
            projectName: r.project.projectName,
            status: r.status,
            failureReason: r.failureReason,
            failureMessage: r.failureMessage,
            createdAt: r.createdAt.toISOString()
        })),
        recentDeployments: recent.map((r) => ({
            id: r.id,
            projectId: r.projectId,
            projectName: r.project.projectName,
            status: r.status,
            createdAt: r.createdAt.toISOString()
        }))
    };
}
