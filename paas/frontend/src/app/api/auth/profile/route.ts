import { NextRequest, NextResponse } from "next/server";
import { requireAuth } from "@/server/auth/auth-guard";
import { updateUserProfile } from "@/server/auth/auth-service";
import { buildSessionCookie } from "@/server/auth/session-cookie";
import { fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function PATCH(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-profile",
            windowMs: 60000,
            maxRequests: 20,
            message: "Too many profile updates. Please wait a minute."
        });
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const body = (await request.json()) as Record<string, unknown>;
        const result = await updateUserProfile(auth.userId, body);
        const res = NextResponse.json({
            user: result.user,
            message: result.message
        });
        res.cookies.set(buildSessionCookie(result.token));
        return res;
    }
    catch (error) {
        return fail(error);
    }
}
