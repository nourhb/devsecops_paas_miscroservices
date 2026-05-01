import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { env } from "@/server/config/env";
import { ValidationError } from "@/server/http/errors";
import { fail, ok } from "@/server/http/response";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const { searchParams } = new URL(request.url);
        const jobName = (searchParams.get("jobName") || env.JENKINS_BUILD_JOB_NAME || "").trim();
        const limit = Number.parseInt(searchParams.get("limit") || "20", 10);
        if (!jobName) {
            throw new ValidationError("jobName is required.");
        }
        const builds = await jenkinsClient.listDashboardBuilds(jobName, Number.isFinite(limit) ? limit : 20);
        return ok({
            jobName,
            builds,
        });
    }
    catch (error) {
        return fail(error);
    }
}
