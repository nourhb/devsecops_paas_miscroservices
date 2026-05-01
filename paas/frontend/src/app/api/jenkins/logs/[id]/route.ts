import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { env } from "@/server/config/env";
import { ValidationError } from "@/server/http/errors";
import { fail, ok } from "@/server/http/response";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
export const runtime = "nodejs";
export async function GET(request: NextRequest, context: {
    params: {
        id: string;
    };
}) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const { searchParams } = new URL(request.url);
        const jobName = (searchParams.get("jobName") || env.JENKINS_BUILD_JOB_NAME || "").trim();
        const buildId = (context.params.id || "").trim();
        if (!jobName) {
            throw new ValidationError("jobName is required.");
        }
        if (!buildId) {
            throw new ValidationError("Build id is required.");
        }
        const result = await jenkinsClient.getDashboardBuildLogs(jobName, buildId);
        return ok({
            jobName,
            ...result,
        });
    }
    catch (error) {
        return fail(error);
    }
}
