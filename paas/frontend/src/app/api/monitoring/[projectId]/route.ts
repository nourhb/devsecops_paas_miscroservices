import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
import { getProjectMonitoringSnapshot } from "@/server/metrics/metrics-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        await assertProjectAccess(params.projectId, auth.userId, auth.role);
        const snapshot = await getProjectMonitoringSnapshot(params.projectId);
        return ok(snapshot);
    }
    catch (error) {
        return fail(error);
    }
}
