import { NextRequest } from "next/server";
import { fail, ok } from "@/server/http/response";
import { verifyEmailToken } from "@/server/auth/auth-service";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-verify-email",
            windowMs: 60000,
            maxRequests: 10
        });
        const body = await request.json();
        const response = await verifyEmailToken(body);
        return ok(response);
    }
    catch (error) {
        return fail(error);
    }
}
