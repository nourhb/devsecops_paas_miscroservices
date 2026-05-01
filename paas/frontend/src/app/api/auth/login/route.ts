import { NextRequest, NextResponse } from "next/server";
import { loginUser } from "@/server/auth/auth-service";
import { fail } from "@/server/http/response";
import { enforceRateLimit } from "@/server/http/rate-limit";
import { buildSessionCookie } from "@/server/auth/session-cookie";
export const runtime = "nodejs";
export async function POST(request: NextRequest) {
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-login",
            windowMs: 60000,
            maxRequests: 8,
            message: "Too many login attempts. Please retry in a minute."
        });
        const body = await request.json();
        const response = await loginUser(body);
        if (!response.token) {
            throw new Error("Login session token was not generated.");
        }
        const res = NextResponse.json({ user: response.user });
        res.cookies.set(buildSessionCookie(response.token));
        return res;
    }
    catch (error) {
        return fail(error);
    }
}
