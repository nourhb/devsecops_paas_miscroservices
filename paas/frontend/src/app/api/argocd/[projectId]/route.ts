import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess, getProjectById } from "@/server/projects/project-service";
import { getArgoApplicationStatus } from "@/server/services/argocd-service";
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
        const project = await getProjectById(params.projectId);
        const status = await getArgoApplicationStatus(project.projectName);
        return ok(status);
    }
    catch (error) {
        return fail(error);
    }
}
