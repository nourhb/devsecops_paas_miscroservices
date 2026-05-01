import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { fail, ok } from "@/server/http/response";
import { getDeployPipelineReadiness } from "@/server/services/deploy-pipeline-readiness";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        return ok(getDeployPipelineReadiness());
    }
    catch (error) {
        return fail(error);
    }
}
