import { NextRequest } from "next/server";
import { registerUser } from "@/server/auth/auth-service";
import { created, fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-register",
            windowMs: 60000,
            maxRequests: 5,
            message: "Too many registration attempts. Please retry in a minute."
        });
        const body = await request.json();
        const response = await registerUser(body);
        return created(response);
    }
    catch (error) {
        return fail(error);
    }
}
