import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { env } from "@/server/config/env";
import { fail, ok } from "@/server/http/response";
import { listRecentDeploymentsForUser } from "@/server/services/deployment-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const raw = request.nextUrl.searchParams.get("limit");
        const parsed = raw ? parseInt(raw, 10) : 20;
        const limit = Number.isFinite(parsed) ? Math.min(40, Math.max(1, parsed)) : 20;
        const deployments = await listRecentDeploymentsForUser(auth.userId, auth.role, limit);
        return ok({
            jenkinsJobName: env.JENKINS_BUILD_JOB_NAME || "paas-deploy",
            deployments: deployments.map((d) => ({
                id: d.id,
                projectId: d.projectId,
                projectName: d.projectName,
                status: d.status,
                createdAt: d.createdAt,
                buildNumber: d.buildNumber
            }))
        });
    }
    catch (error) {
        return fail(error);
    }
}
