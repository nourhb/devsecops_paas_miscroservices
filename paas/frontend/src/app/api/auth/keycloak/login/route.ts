import { NextRequest, NextResponse } from "next/server";
import { startKeycloakLoginAsync, keycloakSsoConfigured } from "@/server/auth/keycloak-sso";
import { enforceRateLimit } from "@/server/http/rate-limit";
export const runtime = "nodejs";
export async function GET(request: NextRequest) {
    if (!keycloakSsoConfigured()) {
        return NextResponse.json({ message: "Keycloak SSO is not enabled." }, { status: 404 });
    }
    try {
        enforceRateLimit(request, {
            keyPrefix: "auth-keycloak-login",
            windowMs: 60000,
            maxRequests: 20,
            message: "Too many sign-in attempts. Please retry in a minute."
        });
        const next = request.nextUrl.searchParams.get("next") || "/dashboard";
        const { redirectUrl, cookies } = await startKeycloakLoginAsync(next);
        const res = NextResponse.redirect(redirectUrl);
        for (const c of cookies) {
            res.cookies.set(c);
        }
        return res;
    }
    catch (error) {
        const message = error instanceof Error ? error.message : "Keycloak sign-in failed.";
        const login = new URL("/login", request.nextUrl.origin);
        login.searchParams.set("kc_error", message.slice(0, 500));
        return NextResponse.redirect(login);
    }
}
