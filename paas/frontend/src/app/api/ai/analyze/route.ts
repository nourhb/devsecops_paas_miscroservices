import { NextRequest, NextResponse } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { analyzeBuildResultWithAi } from "@/server/ai/assistant";
import { fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: "ai-analyze",
            windowMs: 60000,
            maxRequests: 12,
            message: "Too many AI analysis requests. Please retry in a minute."
        });
        const payload = await request.json().catch(() => ({}));
        const result = await analyzeBuildResultWithAi(payload || {});
        return NextResponse.json(result);
    }
    catch (error) {
        return fail(error);
    }
}
