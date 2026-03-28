import { DeploymentJobStatus, type Prisma } from "@prisma/client";
import { prisma } from "@/server/db/prisma";
import type { UserRole } from "@/types";

function accessibleProjectsWhere(userId: string, role: UserRole): Prisma.ProjectWhereInput {
  return role === "ADMIN" ? {} : { createdById: userId };
}

export interface DashboardOverview {
  stats: {
    totalProjects: number;
    totalDeployments: number;
    successRatePercent: number | null;
    activeDeployments: number;
  };
  recentDeployments: {
    id: string;
    projectId: string;
    projectName: string;
    status: DeploymentJobStatus;
    createdAt: string;
  }[];
}

export async function getDashboardOverview(userId: string, role: UserRole): Promise<DashboardOverview> {
  const projects = await prisma.project.findMany({
    where: accessibleProjectsWhere(userId, role),
    select: { id: true }
  });
  const projectIds = projects.map((p) => p.id);

  if (projectIds.length === 0) {
    return {
      stats: {
        totalProjects: 0,
        totalDeployments: 0,
        successRatePercent: null,
        activeDeployments: 0
      },
      recentDeployments: []
    };
  }

  const totalProjects = projectIds.length;

  const succeededStatuses = [DeploymentJobStatus.SUCCESS, DeploymentJobStatus.DEPLOYED];

  const [totalDeployments, activeDeployments, succeededCount, failedCount, recent] = await Promise.all([
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
    })
  ]);

  const terminal = succeededCount + failedCount;
  const successRatePercent = terminal === 0 ? null : Math.round((succeededCount / terminal) * 100);

  return {
    stats: {
      totalProjects,
      totalDeployments,
      successRatePercent,
      activeDeployments
    },
    recentDeployments: recent.map((r) => ({
      id: r.id,
      projectId: r.projectId,
      projectName: r.project.projectName,
      status: r.status,
      createdAt: r.createdAt.toISOString()
    }))
  };
}
