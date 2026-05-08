import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { cancelRunningDeploymentForUser } from "@/server/services/deployment-service";
export const runtime = "nodejs";
export async function POST(_request: NextRequest, { params }: {
    params: {
        id: string;
    };
}) {
    try {
        const auth = await requireAuth(_request, ["ADMIN", "DEVELOPER"]);
        const result = await cancelRunningDeploymentForUser(params.id, auth.userId, auth.role);
        return ok(result);
    }
    catch (error) {
        return fail(error);
    }
}
