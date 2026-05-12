import type { ResponseCookie } from "next/dist/compiled/@edge-runtime/cookies";
import { resolveSecureSessionCookieFlag } from "@/server/auth/session-cookie";
const MAX_AGE_SEC = 60 * 10;
export const KC_STATE_COOKIE = "paas_kc_oauth_state";
export const KC_VERIFIER_COOKIE = "paas_kc_oauth_verifier";
export const KC_NEXT_COOKIE = "paas_kc_oauth_next";
function transientCookie(name: string, value: string, maxAge: number): ResponseCookie {
    return {
        name,
        value,
        httpOnly: true,
        sameSite: "lax",
        secure: resolveSecureSessionCookieFlag(),
        path: "/",
        maxAge
    };
}
export function buildKeycloakOAuthCookies(input: {
    state: string;
    codeVerifier: string;
    nextPath: string;
}): ResponseCookie[] {
    const next = input.nextPath.slice(0, 2000);
    return [
        transientCookie(KC_STATE_COOKIE, input.state, MAX_AGE_SEC),
        transientCookie(KC_VERIFIER_COOKIE, input.codeVerifier, MAX_AGE_SEC),
        transientCookie(KC_NEXT_COOKIE, encodeURIComponent(next), MAX_AGE_SEC)
    ];
}
export function buildExpiredKeycloakOAuthCookies(): ResponseCookie[] {
    return [
        { ...transientCookie(KC_STATE_COOKIE, "", 0), maxAge: 0 },
        { ...transientCookie(KC_VERIFIER_COOKIE, "", 0), maxAge: 0 },
        { ...transientCookie(KC_NEXT_COOKIE, "", 0), maxAge: 0 }
    ];
}
