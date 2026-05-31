import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { deleteProjectForUser, getProjectForUser, updateProjectForUser } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";
export const runtime = "nodejs";
export async function GET(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const includeBuildEnv = request.nextUrl.searchParams.get("includeBuildEnv") === "true";
        const project = await getProjectForUser(params.projectId, auth.userId, auth.role, { revealBuildEnv: includeBuildEnv });
        return ok(project);
    }
    catch (error) {
        return fail(error);
    }
}
export async function PATCH(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const body = await request.json();
        const project = await updateProjectForUser(params.projectId, body, auth.userId, auth.role);
        return ok(project);
    }
    catch (error) {
        return fail(error);
    }
}
export async function DELETE(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        await deleteProjectForUser(params.projectId, auth.userId, auth.role);
        return ok({ deleted: true });
    }
    catch (error) {
        return fail(error);
    }
}
