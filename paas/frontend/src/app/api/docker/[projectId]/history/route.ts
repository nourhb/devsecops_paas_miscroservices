import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess } from "@/server/projects/project-service";
import { listContainerImages } from "@/server/docker/docker-service";
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
        const history = await listContainerImages(params.projectId);
        return ok(history);
    }
    catch (error) {
        return fail(error);
    }
}
