import { NextRequest, NextResponse } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { suggestBuildParameters } from "@/server/integrations/build-hint-service";
import { fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: "build-hint-suggest",
            windowMs: 60000,
            maxRequests: 12,
            message: "Too many autocomplete calls\u2014wait a minute and retry.",
        });
        const payload = await request.json().catch(() => ({}));
        const result = await suggestBuildParameters(payload || {});
        return NextResponse.json(result);
    }
    catch (error) {
        return fail(error);
    }
}
