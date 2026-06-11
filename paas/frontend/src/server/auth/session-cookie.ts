import type { ResponseCookie } from "next/dist/compiled/@edge-runtime/cookies";
import { env } from "@/server/config/env";
const SESSION_COOKIE_NAME = "paas_session";
function parseJwtDurationSeconds(raw: string): number {
    const trimmed = raw.trim();
    const match = /^(\d+)\s*([smhd])?$/i.exec(trimmed);
    if (!match) {
        return 60 * 60 * 2;
    }
    const amount = Number.parseInt(match[1], 10);
    const unit = (match[2] || "s").toLowerCase();
    if (unit === "s") {
        return amount;
    }
    if (unit === "m") {
        return amount * 60;
    }
    if (unit === "h") {
        return amount * 60 * 60;
    }
    if (unit === "d") {
        return amount * 60 * 60 * 24;
    }
    return 60 * 60 * 2;
}
export function sessionCookieMaxAgeSeconds(): number {
    return parseJwtDurationSeconds(env.JWT_EXPIRES_IN);
}
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
        maxAge: sessionCookieMaxAgeSeconds()
    };
}
export function buildExpiredSessionCookie(): ResponseCookie {
    return {
        ...buildSessionCookie(""),
        maxAge: 0
    };
}
