import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { getSecurityMetrics } from "@/server/security/security-service";
import { assertProjectAccess } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
export const runtime = "nodejs";
export async function GET(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        await assertProjectAccess(params.projectId, auth.userId, auth.role);
        const response = await getSecurityMetrics(params.projectId);
        return ok(response);
    }
    catch (error) {
        return fail(error);
    }
}
