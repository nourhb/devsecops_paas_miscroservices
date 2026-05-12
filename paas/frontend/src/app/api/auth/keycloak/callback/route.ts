import { NextRequest, NextResponse } from "next/server";
import { completeKeycloakLogin, keycloakSsoConfigured, readKeycloakOAuthFromRequestCookies } from "@/server/auth/keycloak-sso";
import { buildSessionCookie } from "@/server/auth/session-cookie";
import { buildExpiredKeycloakOAuthCookies } from "@/server/auth/keycloak-oauth-cookies";
import { env } from "@/server/config/env";
export const runtime = "nodejs";
function appOrigin(): string {
    return env.APP_BASE_URL.replace(/\/$/, "");
}
export async function GET(request: NextRequest) {
    if (!keycloakSsoConfigured()) {
        return NextResponse.json({ message: "Keycloak SSO is not enabled." }, { status: 404 });
    }
    try {
        const cookieRead = (name: string) => request.cookies.get(name)?.value;
        const result = await completeKeycloakLogin({
            requestUrl: request.url,
            cookies: readKeycloakOAuthFromRequestCookies(cookieRead)
        });
        const target = new URL(result.redirectPath, `${appOrigin()}/`);
        const res = NextResponse.redirect(target);
        res.cookies.set(buildSessionCookie(result.sessionToken));
        for (const c of result.clearOAuthCookies) {
            res.cookies.set(c);
        }
        return res;
    }
    catch (error) {
        const login = new URL("/login", `${appOrigin()}/`);
        if (error instanceof Error && error.message) {
            login.searchParams.set("kc_error", error.message.slice(0, 500));
        }
        const res = NextResponse.redirect(login);
        for (const c of buildExpiredKeycloakOAuthCookies()) {
            res.cookies.set(c);
        }
        return res;
    }
}
