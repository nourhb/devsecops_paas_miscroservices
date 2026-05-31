import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { writeAuditLog } from "@/server/audit/audit-log";
import { getBuildBackend } from "@/server/build-backend";
import { resolveBuildPlan } from "@/server/build-planner";
import { IntegrationError } from "@/server/http/errors";
import { created, fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
import { createProject, listProjects } from "@/server/projects/project-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const projects = await listProjects(auth.userId, auth.role);
        return ok(projects);
    }
    catch (error) {
        return fail(error);
    }
}
export async function POST(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: `project-create:${auth.userId}`,
            windowMs: 60000,
            maxRequests: 10,
            message: "Too many project creation attempts. Please retry in a minute."
        });
        const body = await request.json();
        const { project, warnings: createWarnings } = await createProject(body, auth.userId);
        const warnings: string[] = [...createWarnings];
        try {
            const backend = getBuildBackend();
            await backend.provisionProjectIntegration(project, resolveBuildPlan(project));
        }
        catch (error) {
            const message = error instanceof IntegrationError
                ? error.details || error.message
                : error instanceof Error
                    ? error.message
                    : "Build integration provisioning failed";
            warnings.push(message);
            console.error("[api/project] provisionProjectIntegration:", message);
        }
        writeAuditLog({
            action: "project.create",
            outcome: "success",
            actorId: auth.userId,
            actorEmail: auth.email,
            targetType: "project",
            targetId: project.id,
            metadata: { warningsCount: warnings.length }
        });
        return created({ project, warnings });
    }
    catch (error) {
        if (error instanceof Error) {
            writeAuditLog({
                action: "project.create",
                outcome: "failure",
                metadata: { message: error.message }
            });
        }
        return fail(error);
    }
}
