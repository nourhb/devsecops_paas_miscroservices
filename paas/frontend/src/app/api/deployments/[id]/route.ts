// API route handles deployments [id] requests
import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { getDeploymentForUser } from "@/server/services/deployment-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest, { params }: {
    params: {
        id: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const payload = await getDeploymentForUser(params.id, auth.userId, auth.role);
        return ok(payload);
    }
    catch (error) {
        return fail(error);
    }
}
