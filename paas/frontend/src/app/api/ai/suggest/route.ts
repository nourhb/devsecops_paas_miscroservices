import { NextRequest, NextResponse } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { suggestBuildParametersWithAi } from "@/server/ai/assistant";
import { fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        requireAuth(request, ["ADMIN", "DEVELOPER"]);
        enforceRateLimit(request, {
            keyPrefix: "ai-suggest",
            windowMs: 60000,
            maxRequests: 12,
            message: "Too many AI suggestion requests. Please retry in a minute."
        });
        const payload = await request.json().catch(() => ({}));
        const result = await suggestBuildParametersWithAi(payload || {});
        return NextResponse.json(result);
    }
    catch (error) {
        return fail(error);
    }
}
