import { NextRequest } from "next/server";
import { resendVerificationEmail } from "@/server/auth/auth-service";
import { fail, ok } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-resend-verification",
            windowMs: 60000,
            maxRequests: 5,
            message: "Too many verification email requests. Please retry in a minute."
        });
        const body = await request.json();
        const response = await resendVerificationEmail(body);
        return ok(response);
    }
    catch (error) {
        return fail(error);
    }
}
