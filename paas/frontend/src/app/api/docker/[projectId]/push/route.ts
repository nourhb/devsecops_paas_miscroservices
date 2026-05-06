import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { assertProjectAccess } from "@/server/projects/project-service";
import { pushDockerImage } from "@/server/docker/docker-service";
import { created, fail } from "@/server/http/response";
export const runtime = "nodejs";
export async function POST(request: NextRequest, { params }: {
    params: {
        projectId: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        await assertProjectAccess(params.projectId, auth.userId, auth.role);
        const result = await pushDockerImage(params.projectId);
        return created(result);
    }
    catch (error) {
        return fail(error);
    }
}
