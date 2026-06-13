import type { ResponseCookie } from "next/dist/compiled/@edge-runtime/cookies";
import { env } from "@/server/config/env";

const SESSION_COOKIE_NAME = "paas_session";

export function jwtExpiresInToSeconds(raw: string): number {
    const trimmed = raw.trim().toLowerCase();
    const match = /^(\d+)(s|m|h|d)?$/.exec(trimmed);
    if (!match) {
        return 60 * 60 * 24;
    }
    const n = Number.parseInt(match[1], 10);
    const unit = match[2] || "h";
    switch (unit) {
        case "s":
            return n;
        case "m":
            return n * 60;
        case "h":
            return n * 60 * 60;
        case "d":
            return n * 60 * 60 * 24;
        default:
            return n * 60 * 60;
    }
}

export function sessionCookieMaxAgeSeconds(): number {
    return jwtExpiresInToSeconds(env.JWT_EXPIRES_IN);
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
    return false;
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
