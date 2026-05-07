import { DeploymentFailureReason, DeploymentJobStatus, Prisma } from "@prisma/client";
import { DEPLOYMENT_LOG_TAIL_MAX_CHARS } from "@/server/constants/deploy";
import { prisma } from "@/server/db/prisma";
import { env } from "@/server/config/env";
import { parseBuildMetadata } from "@/server/build-metadata";
import { getBuildBackend } from "@/server/build-backend";
import { resolveBuildPlan } from "@/server/build-planner";
import { resolveAppUrlForClient } from "@/server/deploy/app-public-url";
import { ApiError, IntegrationError, NotFoundError } from "@/server/http/errors";
import { assertProjectAccess, getProjectById, updateProject } from "@/server/projects/project-service";
import { clearDeploymentFailureFields, recordDeploymentFailure } from "@/server/services/deployment-failure";
import { monitorDeployment } from "@/server/services/jenkins-monitor";
import { reconcileJenkinsDeploymentRecord } from "@/server/services/jenkins-deployment-reconcile";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
import type { ActionResponse, RecentDeploymentListItem, UserRole } from "@/types";
function effectiveTriggerUserId(jwtUserId: string): string | null {
    const override = env.DEPLOYMENT_TRIGGER_USER_ID.trim();
    if (override) {
        return override;
    }
    return jwtUserId;
}
export interface DeploymentStatusPayload {
    id: string;
    projectId: string;
    status: DeploymentJobStatus;
    logs: string;
    buildNumber: number | null;
    buildProvider: string | null;
    buildRunId: string | null;
    artifactImage: string | null;
    artifactDigest: string | null;
    url: string | null;
    failureReason: string | null;
    failureMessage: string | null;
}
export interface DeploymentListItem {
    id: string;
    status: DeploymentJobStatus;
    createdAt: string;
    buildNumber: number | null;
    buildProvider: string | null;
    buildRunId: string | null;
    artifactImage: string | null;
    artifactDigest: string | null;
    url: string | null;
    failureReason: string | null;
    failureMessage: string | null;
}
export async function listDeploymentsForProject(projectId: string, userId: string, role: UserRole): Promise<DeploymentListItem[]> {
    await assertProjectAccess(projectId, userId, role);
    const rows = await prisma.deployment.findMany({
        where: { projectId },
        orderBy: { createdAt: "desc" },
        take: 50,
        select: {
            id: true,
            status: true,
            createdAt: true,
            jenkinsBuildNumber: true,
            logs: true,
            url: true,
            failureReason: true,
            failureMessage: true
        }
    });
    return rows.map((r) => {
        const metadata = parseBuildMetadata(r.logs);
        return {
            id: r.id,
            status: r.status,
            createdAt: r.createdAt.toISOString(),
            buildNumber: r.jenkinsBuildNumber,
            buildProvider: metadata.provider ?? null,
            buildRunId: metadata.runId ?? (r.jenkinsBuildNumber === null ? null : String(r.jenkinsBuildNumber)),
            artifactImage: metadata.artifactImage ?? null,
            artifactDigest: metadata.artifactDigest ?? null,
            url: r.url,
            failureReason: r.failureReason,
            failureMessage: r.failureMessage
        };
    });
}
export async function listRecentDeploymentsForUser(userId: string, role: UserRole, limit: number): Promise<RecentDeploymentListItem[]> {
    const projectFilter: Prisma.ProjectWhereInput = role === "ADMIN"
        ? { deletedAt: null }
        : { createdById: userId, deletedAt: null };
    const rows = await prisma.deployment.findMany({
        where: { project: projectFilter },
        orderBy: { createdAt: "desc" },
        take: limit,
        select: {
            id: true,
            projectId: true,
            status: true,
            createdAt: true,
            jenkinsBuildNumber: true,
            project: { select: { projectName: true } }
        }
    });
    return rows.map((r) => ({
        id: r.id,
        projectId: r.projectId,
        projectName: r.project.projectName,
        status: r.status,
        createdAt: r.createdAt.toISOString(),
        buildNumber: r.jenkinsBuildNumber
    }));
}
export async function runProjectDeployment(projectId: string, jwtUserId: string): Promise<ActionResponse> {
    const project = await getProjectById(projectId);
    const activeDeployment = await prisma.deployment.findFirst({
        where: {
            projectId,
            status: { in: [DeploymentJobStatus.PENDING, DeploymentJobStatus.DEPLOYING] }
        },
        orderBy: { createdAt: "desc" },
        select: { id: true, status: true, jenkinsBuildNumber: true }
    });
    if (activeDeployment) {
        throw new ApiError(409, "A deployment is already running for this project.", {
            details: `Deployment ${activeDeployment.id} is ${activeDeployment.status}. Open it instead of starting another Jenkins run.`,
            data: {
                deploymentId: activeDeployment.id,
                runNumber: activeDeployment.jenkinsBuildNumber
            }
        });
    }
    const triggeredById = effectiveTriggerUserId(jwtUserId);
    const plan = resolveBuildPlan(project);
    const backend = getBuildBackend();
    const baseline = await backend.getDeploymentBaseline(project);
    const deployment = await prisma.deployment.create({
        data: {
            projectId,
            status: DeploymentJobStatus.PENDING,
            logs: "",
            priorJenkinsBuildNumber: baseline.runNumber,
            ...(triggeredById ? { triggeredById } : {})
        }
    });
    let build;
    try {
        build = await backend.triggerDeployment(project, plan);
    }
    catch (e) {
        const message = e instanceof Error ? e.message : String(e);
        const details = e instanceof IntegrationError && e.details ? e.details : message;
        await recordDeploymentFailure(deployment.id, project.id, {
            reason: DeploymentFailureReason.TRIGGER,
            message,
            logs: details
        });
        if (e instanceof IntegrationError) {
            throw new IntegrationError(e.message, {
                details: e.details,
                data: { ...(e.data ?? {}), deploymentId: deployment.id }
            });
        }
        throw new IntegrationError(message, { data: { deploymentId: deployment.id } });
    }
    if (!build.accepted) {
        const msg = "The build backend rejected the deploy trigger. Open deployment logs for the upstream response.";
        await recordDeploymentFailure(deployment.id, project.id, {
            reason: DeploymentFailureReason.TRIGGER,
            message: msg,
            logs: build.logs
        });
        throw new IntegrationError("The build backend did not accept the deploy trigger.", {
            details: build.logs,
            data: {
                deploymentId: deployment.id,
                ...(build.externalUrl ? { jobUrl: build.externalUrl } : {})
            }
        });
    }
    const initialLog = build.logs.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS);
    await prisma.deployment.update({
        where: { id: deployment.id },
        data: {
            status: DeploymentJobStatus.PENDING,
            logs: initialLog,
            jenkinsBuildNumber: build.runNumber,
            ...clearDeploymentFailureFields()
        }
    });
    await updateProject(project.id, {
        lastDeploymentStatus: "QUEUED",
        buildStatus: "QUEUED",
        deploymentLogs: initialLog,
        pendingGitHubPush: Prisma.DbNull
    });
    monitorDeployment(deployment.id, build.runNumber);
    return {
        status: "SUCCESS",
        message: `Deployment queued for ${project.projectName}. Poll GET /api/deployments/${deployment.id} for live status.`,
        deploymentLogUrl: build.externalUrl ?? `${backend.provider}://${project.projectName}/${build.runId ?? "latest"}`,
        deploymentId: deployment.id
    };
}
export async function cancelRunningDeploymentForUser(deploymentId: string, userId: string, role: UserRole): Promise<ActionResponse> {
    const row = await prisma.deployment.findUnique({
        where: { id: deploymentId },
        include: { project: true }
    });
    if (!row) {
        throw new NotFoundError("Deployment not found");
    }
    await assertProjectAccess(row.projectId, userId, role, { includeDeleted: true });
    if (row.status !== DeploymentJobStatus.PENDING && row.status !== DeploymentJobStatus.DEPLOYING) {
        throw new ApiError(409, "This deployment is no longer active.", {
            details: `Current status: ${row.status}`
        });
    }
    if (getBuildBackend().provider !== "jenkins") {
        throw new ApiError(501, "Stopping deployments from the portal requires Jenkins as the build backend.");
    }
    if (!env.JENKINS_BASE_URL?.trim()) {
        throw new IntegrationError("Jenkins is not configured on this server.");
    }
    const { projectName, id: projectId } = row.project;
    const baseline = row.priorJenkinsBuildNumber ?? null;
    let buildNum = row.jenkinsBuildNumber;
    const summary = await jenkinsClient.getLastBuildSummary(projectName, projectId, "deploy");
    if (buildNum === null && summary && summary.building && (baseline === null || summary.number > baseline)) {
        buildNum = summary.number;
        await prisma.deployment.update({
            where: { id: deploymentId },
            data: { jenkinsBuildNumber: buildNum }
        });
    }
    const parts: string[] = [];
    if (buildNum !== null) {
        const meta = await jenkinsClient.getBuildApiJson(projectName, projectId, buildNum, "deploy");
        if (meta?.building) {
            const stopped = await jenkinsClient.stopBuild(projectName, projectId, buildNum, "deploy");
            if (!stopped.ok) {
                throw new IntegrationError("Jenkins did not accept the stop request.", {
                    details: stopped.detail
                });
            }
            parts.push(`Stopped Jenkins run #${buildNum}.`);
        }
        else {
            parts.push(`Jenkins run #${buildNum} is not marked building (may have finished).`);
        }
    }
    const queued = await jenkinsClient.cancelQueuedPipelineItems(projectName, projectId, "deploy");
    if (queued.cancelled > 0) {
        parts.push(queued.detail);
    }
    const append = `\n[paas] Cancel requested from portal. ${parts.join(" ")}`.trimEnd();
    await prisma.deployment.update({
        where: { id: deploymentId },
        data: {
            logs: `${(row.logs ?? "").trimEnd()}${append}`.slice(-DEPLOYMENT_LOG_TAIL_MAX_CHARS)
        }
    });
    await new Promise((r) => setTimeout(r, 1200));
    await reconcileJenkinsDeploymentRecord(deploymentId);
    return {
        status: "SUCCESS",
        message: parts.join(" ") || "Cancellation sent. Refreshing status from Jenkins.",
        deploymentId
    };
}
export async function getDeploymentForUser(deploymentId: string, userId: string, role: UserRole): Promise<DeploymentStatusPayload> {
    const row = await prisma.deployment.findUnique({
        where: { id: deploymentId },
        include: { project: true }
    });
    if (!row) {
        throw new NotFoundError("Deployment not found");
    }
    await assertProjectAccess(row.projectId, userId, role, { includeDeleted: true });
    if (row.status === DeploymentJobStatus.PENDING || row.status === DeploymentJobStatus.DEPLOYING) {
        await reconcileJenkinsDeploymentRecord(deploymentId);
    }
    const fresh = await prisma.deployment.findUnique({
        where: { id: deploymentId },
        include: { project: true }
    });
    if (!fresh) {
        throw new NotFoundError("Deployment not found");
    }
    const metadata = parseBuildMetadata(fresh.logs);
    return {
        id: fresh.id,
        projectId: fresh.projectId,
        status: fresh.status,
        logs: fresh.logs ?? "",
        buildNumber: fresh.jenkinsBuildNumber,
        buildProvider: metadata.provider ?? null,
        buildRunId: metadata.runId ?? (fresh.jenkinsBuildNumber === null ? null : String(fresh.jenkinsBuildNumber)),
        artifactImage: metadata.artifactImage ?? null,
        artifactDigest: metadata.artifactDigest ?? null,
        url: resolveAppUrlForClient(fresh.project.projectName, fresh.url),
        failureReason: fresh.failureReason,
        failureMessage: fresh.failureMessage
    };
}
