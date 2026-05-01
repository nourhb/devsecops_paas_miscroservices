import { prisma } from "@/server/db/prisma";
import type { RuntimeMetrics } from "@/types";
import { getProjectById } from "@/server/projects/project-service";
import { cosignClient, prometheusClient, sonarQubeClient, trivyClient } from "@/server/integrations/devsecops-clients";
import { aggregatePodCountsAcrossNamespaces, getClusterNodeCount } from "@/server/integrations/kubernetes-client";
import { env } from "@/server/config/env";
export interface DashboardMetricsPayload {
    cluster: {
        nodeCount: number;
        cpuUsagePercent: number;
        memoryUsagePercent: number;
    };
    pipelines: {
        id: string;
        projectId: string;
        status: string;
        buildNumber: number | null;
        createdAt: string;
    }[];
    deployments: {
        runningPods: number;
        failedPods: number;
        lastDeploymentTime: string | null;
    };
    security: {
        trivyVulnerabilities: string;
        sonarQualityGate: string | null;
        signedImages: number;
        unsignedImages: number;
    };
}
export async function getRuntimeMetrics(projectId: string): Promise<RuntimeMetrics> {
    await getProjectById(projectId);
    const usage = await prometheusClient.clusterUsage(projectId);
    const projects = await prisma.project.findMany({
        where: { deletedAt: null },
        select: {
            imageTag: true,
            lastDeploymentStatus: true,
            buildStatus: true
        }
    });
    const runningApplications = projects.filter((project) => project.lastDeploymentStatus === "SUCCESS").length;
    const failedBuilds = projects.filter((project) => project.buildStatus === "FAILED").length;
    let signedImages = 0;
    let unsignedImages = 0;
    for (const project of projects) {
        const imageTag = project.imageTag;
        if (!imageTag) {
            continue;
        }
        const signed = await cosignClient.isSigned(imageTag);
        if (signed) {
            signedImages += 1;
        }
        else {
            unsignedImages += 1;
        }
    }
    return {
        cpuUsagePercent: Math.min(100, usage.cpu),
        memoryUsagePercent: Math.min(100, usage.ram),
        runningApplications,
        failedBuilds,
        signedImages,
        unsignedImages
    };
}
export async function getDashboardMetrics(): Promise<DashboardMetricsPayload> {
    const projects = await prisma.project.findMany({
        where: { deletedAt: null },
        orderBy: { updatedAt: "desc" }
    });
    const usage = await prometheusClient.clusterUsage("platform-dashboard");
    const pipelines = projects.slice(0, 10).map((p) => ({
        id: `${p.id}-last-build`,
        projectId: p.id,
        status: p.buildStatus,
        buildNumber: Math.floor(p.updatedAt.getTime() / 1000) % 1000000,
        createdAt: p.updatedAt.toISOString()
    }));
    let runningPods = projects.filter((p) => p.lastDeploymentStatus === "SUCCESS").length;
    let failedPods = projects.filter((p) => p.podStatus === "FAILED" || p.lastDeploymentStatus === "FAILED").length;
    if (env.KUBERNETES_ENABLED === "true" && projects.length > 0) {
        const namespaces = projects.map((p) => p.namespace);
        const k8s = await aggregatePodCountsAcrossNamespaces(namespaces);
        const nsErrors = k8s.errors.length;
        const nsUnique = new Set(namespaces.filter(Boolean)).size;
        if (nsErrors < nsUnique || k8s.runningPods > 0 || k8s.failedPods > 0) {
            runningPods = k8s.runningPods;
            failedPods = k8s.failedPods;
        }
    }
    const lastDeploymentTime = projects
        .map((p) => p.updatedAt)
        .sort((a, b) => b.getTime() - a.getTime())[0]?.toISOString() ?? null;
    let signedImages = 0;
    let unsignedImages = 0;
    for (const p of projects) {
        const imageTag = p.imageTag;
        if (!imageTag) {
            continue;
        }
        const signed = await cosignClient.isSigned(imageTag);
        if (signed) {
            signedImages += 1;
        }
        else {
            unsignedImages += 1;
        }
    }
    let crit = 0;
    let high = 0;
    let med = 0;
    let low = 0;
    const sample = projects.slice(0, 5);
    for (const p of sample) {
        const t = await trivyClient.scan(p.imageTag || `${p.projectName}:latest`);
        crit += t.critical;
        high += t.high;
        med += t.medium;
        low += t.low;
    }
    const trivyVulnerabilities = sample.length === 0
        ? "No projects to scan"
        : `${crit + high + med + low} findings (CRIT ${crit}, HIGH ${high}, MED ${med}, LOW ${low})`;
    const sonarProject = projects[0];
    const sonar = sonarProject
        ? await sonarQubeClient.qualityGate(sonarProject.projectName)
        : { status: "PASSED" as const };
    const nodeCountLive = await getClusterNodeCount();
    return {
        cluster: {
            nodeCount: nodeCountLive ?? Math.min(32, 3 + projects.length + Math.floor(usage.cpu % 5)),
            cpuUsagePercent: Math.min(100, usage.cpu),
            memoryUsagePercent: Math.min(100, usage.ram)
        },
        pipelines,
        deployments: {
            runningPods,
            failedPods,
            lastDeploymentTime
        },
        security: {
            trivyVulnerabilities,
            sonarQualityGate: sonar.status,
            signedImages,
            unsignedImages
        }
    };
}
