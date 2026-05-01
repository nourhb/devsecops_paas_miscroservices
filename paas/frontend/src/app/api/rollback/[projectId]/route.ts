import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { writeAuditLog } from "@/server/audit/audit-log";
import { rollbackProject } from "@/server/pipeline/pipeline-service";
import { assertProjectAccess } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: `project-rollback:${auth.userId}`,
            windowMs: 60000,
            maxRequests: 6,
            message: "Too many rollback requests. Please retry in a minute."
        });
        await assertProjectAccess(params.projectId, auth.userId, auth.role);
        const response = await rollbackProject(params.projectId);
        writeAuditLog({
            action: "deploy.rollback",
            outcome: "success",
            actorId: auth.userId,
            actorEmail: auth.email,
            targetType: "project",
            targetId: params.projectId
        });
        return ok(response);
    }
    catch (error) {
        if (error instanceof Error) {
            writeAuditLog({
                action: "deploy.rollback",
                outcome: "failure",
                targetType: "project",
                targetId: params.projectId,
                metadata: { message: error.message }
            });
        }
        return fail(error);
    }
}
