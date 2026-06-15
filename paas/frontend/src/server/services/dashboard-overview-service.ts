import { DeploymentJobStatus, type Prisma } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import { listClusterDeployments, listClusterPods, listClusterServices } from "@/server/integrations/kubernetes-client";
import { listPlatformArtifacts } from "@/server/artifacts/artifact-service";
import { getPlatformTooling } from "@/server/platform/platform-tooling";
import { getSecurityMetrics } from "@/server/security/security-service";
import { TtlCache } from "@/server/http/ttl-cache";
import type { ArtifactRecord, PlatformToolGroup, SeverityBreakdown, UserRole } from "@/types";
function accessibleProjectsWhere(userId: string, role: UserRole): Prisma.ProjectWhereInput {
    return role === "ADMIN" ? { deletedAt: null } : { createdById: userId, deletedAt: null };
}
export type DashboardClusterDataSource = "kubernetes" | "project_rollups" | "none";
function rollUpClusterFromProjects(projects: Array<{
    lastDeploymentStatus: string;
    podStatus: string;
    url: string | null;
}>, totalDeployments: number, succeededDeployments: number): {
    pods: number;
    runningPods: number;
    unhealthyPods: number;
    services: number;
    deployments: number;
    healthyDeployments: number;
} {
    const runningPods = projects.filter((p) => {
        const d = (p.lastDeploymentStatus || "").toUpperCase();
        if (d === "DEPLOYED" || d === "SUCCESS") {
            return true;
        }
        return /\d+\s*running/i.test(p.podStatus || "") || /\brunning\b/i.test(p.podStatus || "");
    }).length;
    const unhealthyPods = projects.filter((p) => {
        if ((p.lastDeploymentStatus || "").toUpperCase() === "FAILED") {
            return true;
        }
        const ps = (p.podStatus || "").toUpperCase();
        return ps.includes("FAIL") || ps.includes("ERROR") || ps.includes("CRASH") || ps === "UNKNOWN";
    }).length;
    return {
        pods: projects.length,
        runningPods,
        unhealthyPods,
        services: projects.filter((p) => Boolean(p.url?.trim())).length,
        deployments: totalDeployments,
        healthyDeployments: succeededDeployments
    };
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
        medium: number;
        low: number;
        unsignedImages: number;
        policyBlocked: number;
        dependencyTrack: SeverityBreakdown;
        trivy: SeverityBreakdown;
        sonar: {
            passed: number;
            failed: number;
            unknown: number;
        };
        opa: {
            violationCount: number;
            projectsWithViolations: number;
            projectsWithPolicyGap: number;
        };
        kyverno: {
            projectsWithPolicyGap: number;
        };
        sampledProjects: number;
    };
    artifacts: ArtifactRecord[];
    platformTools: PlatformToolGroup[];
    projects: {
        id: string;
        projectName: string;
        namespace: string;
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
    clusterDataSource: DashboardClusterDataSource;
}
const emptySeverity: SeverityBreakdown = {
    critical: 0,
    high: 0,
    medium: 0,
    low: 0
};
const SECURITY_SAMPLE_LIMIT = 3;
const SECURITY_METRICS_BUDGET_MS = 4000;
const dashboardOverviewCache = new TtlCache<DashboardOverview>(25_000);

function sleep(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function safeSecurityMetrics(projectId: string): Promise<Awaited<ReturnType<typeof getSecurityMetrics>> | null> {
    try {
        return await Promise.race([
            getSecurityMetrics(projectId),
            sleep(SECURITY_METRICS_BUDGET_MS).then(() => {
                throw new Error(`security metrics timed out after ${SECURITY_METRICS_BUDGET_MS}ms`);
            })
        ]);
    }
    catch {
        return null;
    }
}

async function rollupSecurityForDashboard(projectIds: string[]): Promise<DashboardOverview["security"]> {
    if (projectIds.length === 0) {
        return {
            score: 100,
            critical: 0,
            high: 0,
            medium: 0,
            low: 0,
            unsignedImages: 0,
            policyBlocked: 0,
            dependencyTrack: { ...emptySeverity },
            trivy: { ...emptySeverity },
            sonar: { passed: 0, failed: 0, unknown: 0 },
            opa: { violationCount: 0, projectsWithViolations: 0, projectsWithPolicyGap: 0 },
            kyverno: { projectsWithPolicyGap: 0 },
            sampledProjects: 0
        };
    }
    const settled = await Promise.all(projectIds.map((id) => safeSecurityMetrics(id)));
    const metricsList = settled.filter((m): m is NonNullable<typeof m> => m !== null);
    let dtSum = { ...emptySeverity };
    let trivySum = { ...emptySeverity };
    let scoreSum = 0;
    let unsignedImages = 0;
    let policyBlocked = 0;
    const sonar = { passed: 0, failed: 0, unknown: 0 };
    let opaViolationCount = 0;
    let opaProjectsWithViolations = 0;
    let opaPolicyGap = 0;
    let kyvernoGap = 0;
    for (const m of metricsList) {
        dtSum = sumSeverity(dtSum, m.dependencyTrack);
        trivySum = sumSeverity(trivySum, m.trivy);
        scoreSum += m.securityScore;
        if (!m.cosignSigned) {
            unsignedImages += 1;
        }
        if (!m.securityEnforcement?.deploymentAllowed) {
            policyBlocked += 1;
        }
        const q = String(m.qualityGateStatus || "").toUpperCase();
        if (q === "PASSED") {
            sonar.passed += 1;
        }
        else if (q === "FAILED") {
            sonar.failed += 1;
        }
        else {
            sonar.unknown += 1;
        }
        if (m.opaViolations > 0) {
            opaProjectsWithViolations += 1;
            opaViolationCount += m.opaViolations;
        }
        const engine = m.securityEnforcement?.policyEngine;
        if (engine === "Kyverno" && m.securityEnforcement && !m.securityEnforcement.policyValidated) {
            kyvernoGap += 1;
        }
        if (engine === "OPA" && m.securityEnforcement && !m.securityEnforcement.policyValidated) {
            opaPolicyGap += 1;
        }
    }
    const n = metricsList.length;
    return {
        score: n === 0 ? 100 : Math.max(0, Math.min(100, Math.round(scoreSum / n))),
        critical: dtSum.critical + trivySum.critical,
        high: dtSum.high + trivySum.high,
        medium: dtSum.medium + trivySum.medium,
        low: dtSum.low + trivySum.low,
        unsignedImages,
        policyBlocked,
        dependencyTrack: dtSum,
        trivy: trivySum,
        sonar,
        opa: {
            violationCount: opaViolationCount,
            projectsWithViolations: opaProjectsWithViolations,
            projectsWithPolicyGap: opaPolicyGap
        },
        kyverno: { projectsWithPolicyGap: kyvernoGap },
        sampledProjects: n
    };
}

function sumSeverity(a: SeverityBreakdown, b: SeverityBreakdown): SeverityBreakdown {
    return {
        critical: a.critical + b.critical,
        high: a.high + b.high,
        medium: a.medium + b.medium,
        low: a.low + b.low
    };
}
export async function getDashboardOverview(userId: string, role: UserRole): Promise<DashboardOverview> {
    const cacheKey = `${userId}:${role}`;
    const cached = dashboardOverviewCache.get(cacheKey);
    if (cached) {
        return cached;
    }
    const projects = await prisma.project.findMany({
        where: accessibleProjectsWhere(userId, role),
        orderBy: { updatedAt: "desc" },
        select: {
            id: true,
            projectName: true,
            namespace: true,
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
                medium: 0,
                low: 0,
                unsignedImages: 0,
                policyBlocked: 0,
                dependencyTrack: { ...emptySeverity },
                trivy: { ...emptySeverity },
                sonar: { passed: 0, failed: 0, unknown: 0 },
                opa: { violationCount: 0, projectsWithViolations: 0, projectsWithPolicyGap: 0 },
                kyverno: { projectsWithPolicyGap: 0 },
                sampledProjects: 0
            },
            artifacts: [],
            platformTools: [],
            projects: [],
            failedDeployments: [],
            recentDeployments: [],
            clusterDataSource: "none"
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
    const useKubernetesCluster = pods.configured && !pods.error;
    let runningPods: number;
    let unhealthyPods: number;
    let cluster: DashboardOverview["cluster"];
    let clusterDataSource: DashboardClusterDataSource;
    if (useKubernetesCluster) {
        runningPods = pods.items.filter((pod) => pod.status === "Running").length;
        unhealthyPods = pods.items.filter((pod) => pod.health !== "Healthy" && pod.health !== "Succeeded").length;
        const healthyDeployments = k8sDeployments.items.filter((deployment) => deployment.ready === `${deployment.replicas}/${deployment.replicas}`).length;
        cluster = {
            pods: pods.items.length,
            runningPods,
            services: services.items.length,
            deployments: k8sDeployments.items.length,
            healthyDeployments
        };
        clusterDataSource = "kubernetes";
    }
    else {
        const rollup = rollUpClusterFromProjects(projects, totalDeployments, succeededCount);
        runningPods = rollup.runningPods;
        unhealthyPods = rollup.unhealthyPods;
        cluster = {
            pods: rollup.pods,
            runningPods: rollup.runningPods,
            services: rollup.services,
            deployments: rollup.deployments,
            healthyDeployments: rollup.healthyDeployments
        };
        clusterDataSource = "project_rollups";
    }
    const securityRollup = await rollupSecurityForDashboard(projectIds.slice(0, SECURITY_SAMPLE_LIMIT));
    const overview: DashboardOverview = {
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
        cluster,
        security: securityRollup,
        artifacts: artifactsPayload.artifacts.slice(0, 8),
        platformTools: tooling.groups,
        projects: projects.slice(0, 25).map((project) => ({
            id: project.id,
            projectName: project.projectName,
            namespace: project.namespace || "default",
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
        })),
        clusterDataSource
    };
    dashboardOverviewCache.set(cacheKey, overview);
    return overview;
}
