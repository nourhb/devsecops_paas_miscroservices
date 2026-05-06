import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { writeAuditLog } from "@/server/audit/audit-log";
import { assertProjectAccess, clearPendingGitHubPush } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
import { triggerBuild } from "@/server/pipeline/pipeline-service";
export const runtime = "nodejs";
export async function POST(request: NextRequest, { params }: { params: { projectId: string } }) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: `project-build:${auth.userId}`,
            windowMs: 60000,
            maxRequests: 16,
            message: "Too many build requests. Please retry in a minute."
        });
        await assertProjectAccess(params.projectId, auth.userId, auth.role);
        const body = (await request.json().catch(() => ({}))) as {
            branch?: string;
            gitCredentialsId?: string;
            dismissPendingGitHubPush?: boolean;
        };
        if (body.dismissPendingGitHubPush === true) {
            await clearPendingGitHubPush(params.projectId);
            writeAuditLog({
                action: "build.pending-github-push.dismiss",
                outcome: "success",
                actorId: auth.userId,
                actorEmail: auth.email,
                targetType: "project",
                targetId: params.projectId
            });
            return ok({ status: "SUCCESS", message: "Pending GitHub push prompt cleared." });
        }
        const response = await triggerBuild(params.projectId, {
            branchOverride: body.branch?.trim() || undefined,
            gitCredentialsIdOverride: body.gitCredentialsId !== undefined ? body.gitCredentialsId.trim() || null : undefined
        });
        writeAuditLog({
            action: "build.trigger",
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
                action: "build.trigger",
                outcome: "failure",
                targetType: "project",
                targetId: params.projectId,
                metadata: { message: error.message }
            });
        }
        return fail(error);
    }
}
