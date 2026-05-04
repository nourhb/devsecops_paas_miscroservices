import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { ValidationError } from "@/server/http/errors";
import { fail, ok } from "@/server/http/response";
import { jenkinsClient } from "@/server/integrations/devsecops-clients";
export const runtime = "nodejs";
export async function POST(req: NextRequest) {
    try {
        requireAuth(req, ["ADMIN", "DEVELOPER"]);
        const json = (await req.json()) as {
            jobName?: string;
            parameters?: Record<string, string>;
        };
        const job = String(json.jobName || "").trim();
        if (!job) {
            throw new ValidationError("jobName is required.");
        }
        const params = json.parameters && typeof json.parameters === "object" ? json.parameters : {};
        const out = await jenkinsClient.triggerDashboardBuild(job, params);
        return ok(out);
    }
    catch (error) {
        return fail(error);
    }
}
