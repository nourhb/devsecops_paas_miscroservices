import { NextRequest } from "next/server";
import { requestPasswordReset } from "@/server/auth/auth-service";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-forgot-password",
            windowMs: 60000,
            maxRequests: 5,
            message: "Too many password reset requests. Please retry in a minute."
        });
        const body = await request.json();
        const response = await requestPasswordReset(body);
        return ok(response);
    }
    catch (error) {
        return fail(error);
    }
}
