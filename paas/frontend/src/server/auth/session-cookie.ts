import type { ResponseCookie } from "next/dist/compiled/@edge-runtime/cookies";
const SESSION_COOKIE_NAME = "paas_session";
const SESSION_COOKIE_MAX_AGE_SECONDS = 60 * 60 * 2;
export function resolveSecureSessionCookieFlag() {
    const explicit = process.env.SESSION_COOKIE_SECURE?.trim().toLowerCase();
    if (explicit === "true") {
        return true;
    }
    if (explicit === "false") {
        return false;
    }
    const base = (process.env.APP_BASE_URL || "").trim().toLowerCase();
    if (base.startsWith("https://")) {
        return true;
    }
    if (base.startsWith("http://")) {
        return false;
    }
    return process.env.NODE_ENV === "production";
}
export function getSessionCookieName() {
    return SESSION_COOKIE_NAME;
}
export function buildSessionCookie(token: string): ResponseCookie {
    return {
        name: SESSION_COOKIE_NAME,
        value: token,
        httpOnly: true,
        sameSite: "lax",
        secure: resolveSecureSessionCookieFlag(),
        path: "/",
        maxAge: SESSION_COOKIE_MAX_AGE_SECONDS
    };
}
export function buildExpiredSessionCookie(): ResponseCookie {
    return {
        ...buildSessionCookie(""),
        maxAge: 0
    };
}
