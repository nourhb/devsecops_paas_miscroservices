import { NextRequest, NextResponse } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { summarizeBuildOutcome } from "@/server/integrations/build-hint-service";
import { fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";

export const runtime = "nodejs";

export async function POST(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: "build-hint-analyze",
            windowMs: 60000,
            maxRequests: 12,
            message: "Too many log summaries—slow down for a minute.",
        });
        const payload = await request.json().catch(() => ({}));
        const result = await summarizeBuildOutcome(payload || {});
        return NextResponse.json(result);
    }
    catch (error) {
        return fail(error);
    }
}
