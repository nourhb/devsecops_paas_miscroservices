import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { assertProjectAccess } from "@/server/projects/project-service";
import type { UserRole } from "@/types";

export interface AppReachabilityResult {
  url: string | null;
  reachable: boolean;
  statusCode: number | null;
  error?: string;
}

/**
 * Server-side HTTP probe of {@link Project.url} (HEAD then GET). Requires project access.
 */
export async function probeProjectAppReachability(
  projectId: string,
  userId: string,
  role: UserRole
): Promise<AppReachabilityResult> {
  await assertProjectAccess(projectId, userId, role);
  const project = await prisma.project.findUnique({
    where: { id: projectId },
    select: { url: true }
  });
  const url = project?.url?.trim() ?? null;
  if (!url) {
    return { url: null, reachable: false, statusCode: null, error: "no_url" };
  }

  const ms = env.APPS_REACHABILITY_TIMEOUT_MS;
  for (const method of ["HEAD", "GET"] as const) {
    try {
      const res = await fetch(url, {
        method,
        redirect: "follow",
        signal: AbortSignal.timeout(ms)
      });
      const reachable = res.status >= 200 && res.status < 400;
      return { url, reachable, statusCode: res.status };
    } catch {
      /* try GET if HEAD unsupported */
    }
  }

  return {
    url,
    reachable: false,
    statusCode: null,
    error: "unreachable"
  };
}
