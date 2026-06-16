import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { getPipelineHelp } from "@/server/help/pipeline-help-service";
import { assertProjectAccess } from "@/server/projects/project-service";
import { fail, ok } from "@/server/http/response";

export const runtime = "nodejs";

export async function GET(request: NextRequest, { params }: {
    params: {
        id: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        await assertProjectAccess(params.id, auth.userId, auth.role);
        const response = await getPipelineHelp(params.id);
        return ok(response);
    }
    catch (error) {
        return fail(error);
    }
}
