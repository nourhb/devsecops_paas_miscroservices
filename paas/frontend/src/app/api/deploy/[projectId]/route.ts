import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { writeAuditLog } from "@/server/audit/audit-log";
import { assertProjectAccess } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
import { runProjectDeployment } from "@/server/services/deployment-service";
export const runtime = "nodejs";
export async function POST(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: `project-deploy:${auth.userId}`,
            windowMs: 60000,
            maxRequests: 8,
            message: "Too many deployment requests. Please retry in a minute."
        });
        await assertProjectAccess(params.projectId, auth.userId, auth.role);
        const response = await runProjectDeployment(params.projectId, auth.userId);
        writeAuditLog({
            action: "deploy.trigger",
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
                action: "deploy.trigger",
                outcome: "failure",
                targetType: "project",
                targetId: params.projectId,
                metadata: { message: error.message }
            });
        }
        return fail(error);
    }
}
