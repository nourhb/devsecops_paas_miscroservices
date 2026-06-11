import { NextRequest, NextResponse } from "next/server";
import * as jwt from "jsonwebtoken";
import { requireAuth } from "@/server/auth/auth-guard";
import { getAuthUserById } from "@/server/auth/auth-service";
import { buildSessionCookie, getSessionCookieName } from "@/server/auth/session-cookie";
import { fail } from "@/server/http/response";
import { signToken } from "@/server/security/jwt";

export const runtime = "nodejs";

function refreshedSessionToken(request: NextRequest, auth: {
    userId: string;
    email: string;
    role: string;
}): string | null {
    const token = request.cookies.get(getSessionCookieName())?.value?.trim();
    if (!token) {
        return null;
    }
    try {
        const decoded = jwt.decode(token) as {
            exp?: number;
        } | null;
        const expMs = decoded?.exp ? decoded.exp * 1000 : 0;
        if (!expMs) {
            return null;
        }
        const remainingMs = expMs - Date.now();
        const refreshThresholdMs = 30 * 60 * 1000;
        if (remainingMs > refreshThresholdMs) {
            return null;
        }
        return signToken({
            userId: auth.userId,
            email: auth.email,
            role: auth.role as "ADMIN" | "DEVELOPER"
        });
    }
    catch {
        return null;
    }
}

export async function GET(request: NextRequest) {
    try {
        const auth = await requireAuth(request, ["ADMIN", "DEVELOPER"]);
        const user = await getAuthUserById(auth.userId);
        const body = {
            authenticated: true,
            user: {
                id: auth.userId,
                email: user?.email ?? auth.email,
                fullName: user?.fullName || auth.email,
                role: auth.role,
                accountKind: user?.keycloakSub ? "keycloak" : "local"
            }
        };
        const res = NextResponse.json(body, { status: 200 });
        const newToken = refreshedSessionToken(request, auth);
        if (newToken) {
            res.cookies.set(buildSessionCookie(newToken));
        }
        return res;
    }
    catch (error) {
        return fail(error);
    }
}
