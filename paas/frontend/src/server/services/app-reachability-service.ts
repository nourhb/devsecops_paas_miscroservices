import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { assertProjectAccess } from "@/server/projects/project-service";
import type { UserRole } from "@/types";
function isLikelySyntheticLocalHostname(url: string): boolean {
    try {
        const host = new URL(url).hostname.toLowerCase();
        return host.endsWith(".local") || host === "localhost" || host.endsWith(".localhost");
    }
    catch {
        return false;
    }
}
export interface AppReachabilityResult {
    url: string | null;
    reachable: boolean;
    statusCode: number | null;
    error?: string;
}
export async function probeProjectAppReachability(projectId: string, userId: string, role: UserRole): Promise<AppReachabilityResult> {
    await assertProjectAccess(projectId, userId, role);
    const project = await prisma.project.findFirst({
        where: { id: projectId, deletedAt: null },
        select: { url: true }
    });
    const url = project?.url?.trim() ?? null;
    if (!url) {
        return { url: null, reachable: false, statusCode: null, error: "no_url" };
    }
    if (isLikelySyntheticLocalHostname(url)) {
        return {
            url,
            reachable: false,
            statusCode: null,
            error: "synthetic_local"
        };
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
        }
        catch {
        }
    }
    return {
        url,
        reachable: false,
        statusCode: null,
        error: "unreachable"
    };
}
