import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { probeProjectAppReachability } from "@/server/services/app-reachability-service";
export const runtime = "nodejs";
export async function GET(request: NextRequest, { params }: {
    params: {
        id: string;
    };
}) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const result = await probeProjectAppReachability(params.id, auth.userId, auth.role);
        return ok(result);
    }
    catch (error) {
        return fail(error);
    }
}
