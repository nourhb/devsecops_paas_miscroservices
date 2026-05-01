import { NextRequest } from "next/server";
import { resetPassword } from "@/server/auth/auth-service";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-reset-password",
            windowMs: 60000,
            maxRequests: 8,
            message: "Too many password reset attempts. Please retry in a minute."
        });
        const body = await request.json();
        const response = await resetPassword(body);
        return ok(response);
    }
    catch (error) {
        return fail(error);
    }
}
