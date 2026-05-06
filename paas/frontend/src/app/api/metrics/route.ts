import { NextRequest } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { getDashboardMetrics } from "@/server/metrics/metrics-service";
import { fail, ok } from "@/server/http/response";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const metrics = await getDashboardMetrics();
        return ok(metrics);
    }
    catch (error) {
        return fail(error);
    }
}
