import * as jwt from "jsonwebtoken";
import { generators, Issuer } from "openid-client";
import type { BaseClient } from "openid-client";
import { Role } from "@prisma/client";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { buildExpiredKeycloakOAuthCookies, buildKeycloakOAuthCookies, KC_NEXT_COOKIE, KC_STATE_COOKIE, KC_VERIFIER_COOKIE } from "@/server/auth/keycloak-oauth-cookies";
import { signToken } from "@/server/security/jwt";
import { ApiError, ValidationError } from "@/server/http/errors";
import type { UserRole } from "@/types";
import type { ResponseCookie } from "next/dist/compiled/@edge-runtime/cookies";
let clientMemo: BaseClient | null = null;
export function keycloakSsoConfigured(): boolean {
    return (env.KEYCLOAK_ENABLED === "true" &&
        Boolean(env.KEYCLOAK_ISSUER.trim() &&
            env.KEYCLOAK_CLIENT_ID.trim() &&
            env.KEYCLOAK_CLIENT_SECRET.trim()));
}
function appOrigin(): string {
    return env.APP_BASE_URL.replace(/\/$/, "");
}
export function keycloakRedirectUri(): string {
    return `${appOrigin()}/api/auth/keycloak/callback`;
}
async function getKeycloakOpenIdClient(): Promise<BaseClient> {
    if (clientMemo) {
        return clientMemo;
    }
    const issuerUrl = env.KEYCLOAK_ISSUER.replace(/\/$/, "");
    const issuer = await Issuer.discover(issuerUrl);
    const client = new issuer.Client({
        client_id: env.KEYCLOAK_CLIENT_ID,
        client_secret: env.KEYCLOAK_CLIENT_SECRET,
        redirect_uris: [keycloakRedirectUri()],
        response_types: ["code"]
    });
    clientMemo = client;
    return client;
}
function mergeRole(existing: Role, fromKeycloak: Role): Role {
    if (existing === Role.ADMIN || fromKeycloak === Role.ADMIN) {
        return Role.ADMIN;
    }
    return Role.DEVELOPER;
}
function roleFromAccessToken(accessToken: string | undefined): Role {
    const adminRole = env.KEYCLOAK_ADMIN_ROLE.trim();
    if (!adminRole || !accessToken) {
        return Role.DEVELOPER;
    }
    const decoded = jwt.decode(accessToken);
    if (!decoded || typeof decoded !== "object") {
        return Role.DEVELOPER;
    }
    const realmAccess = Reflect.get(decoded, "realm_access") as {
        roles?: string[];
    } | undefined;
    const roles = realmAccess?.roles ?? [];
    return roles.includes(adminRole) ? Role.ADMIN : Role.DEVELOPER;
}
function pickEmail(claims: {
    email?: unknown;
    preferred_username?: unknown;
}): string {
    const emailRaw = typeof claims.email === "string" ? claims.email.trim() : "";
    if (emailRaw) {
        return emailRaw.toLowerCase();
    }
    const preferred = typeof claims.preferred_username === "string" ? claims.preferred_username.trim() : "";
    if (preferred.includes("@")) {
        return preferred.toLowerCase();
    }
    return "";
}
function pickFullName(claims: {
    name?: unknown;
    preferred_username?: unknown;
}, email: string): string {
    if (typeof claims.name === "string" && claims.name.trim()) {
        return claims.name.trim();
    }
    if (typeof claims.preferred_username === "string" && claims.preferred_username.trim()) {
        return claims.preferred_username.trim();
    }
    return email.split("@")[0] || "User";
}
async function upsertUserFromKeycloak(input: {
    sub: string;
    email: string;
    fullName: string;
    keycloakRole: Role;
}) {
    const existingBySub = await prisma.user.findUnique({ where: { keycloakSub: input.sub } });
    if (existingBySub) {
        const role = mergeRole(existingBySub.role, input.keycloakRole);
        return prisma.user.update({
            where: { id: existingBySub.id },
            data: {
                email: input.email,
                fullName: input.fullName,
                role,
                emailVerifiedAt: new Date()
            }
        });
    }
    const existingByEmail = await prisma.user.findUnique({ where: { email: input.email } });
    if (existingByEmail) {
        if (existingByEmail.keycloakSub && existingByEmail.keycloakSub !== input.sub) {
            throw new ApiError(409, "This email is already linked to a different Keycloak user.");
        }
        const role = mergeRole(existingByEmail.role, input.keycloakRole);
        return prisma.user.update({
            where: { id: existingByEmail.id },
            data: {
                keycloakSub: input.sub,
                fullName: input.fullName,
                role,
                emailVerifiedAt: new Date()
            }
        });
    }
    return prisma.user.create({
        data: {
            email: input.email,
            fullName: input.fullName,
            keycloakSub: input.sub,
            passwordHash: null,
            role: input.keycloakRole,
            emailVerifiedAt: new Date()
        }
    });
}
export async function startKeycloakLoginAsync(nextPath: string): Promise<{
    redirectUrl: string;
    cookies: ResponseCookie[];
}> {
    if (!keycloakSsoConfigured()) {
        throw new ValidationError("Keycloak SSO is not configured.");
    }
    const safeNext = nextPath.startsWith("/") ? nextPath : "/dashboard";
    const client = await getKeycloakOpenIdClient();
    const codeVerifier = generators.codeVerifier();
    const codeChallenge = generators.codeChallenge(codeVerifier);
    const state = generators.state();
    const redirectUrl = client.authorizationUrl({
        scope: "openid email profile",
        state,
        code_challenge: codeChallenge,
        code_challenge_method: "S256"
    });
    return {
        redirectUrl,
        cookies: buildKeycloakOAuthCookies({
            state,
            codeVerifier,
            nextPath: safeNext
        })
    };
}
export async function completeKeycloakLogin(input: {
    requestUrl: string;
    cookies: {
        state: string | undefined;
        codeVerifier: string | undefined;
        nextPath: string | undefined;
    };
}): Promise<{
    sessionToken: string;
    user: {
        id: string;
        email: string;
        fullName: string;
        role: UserRole;
    };
    redirectPath: string;
    clearOAuthCookies: ResponseCookie[];
}> {
    const client = await getKeycloakOpenIdClient();
    const params = client.callbackParams(input.requestUrl);
    if (params.error) {
        const desc = typeof params.error_description === "string" ? params.error_description : params.error;
        throw new ValidationError(desc || "Keycloak authorization failed.");
    }
    const state = input.cookies.state;
    const codeVerifier = input.cookies.codeVerifier;
    if (!state || !codeVerifier) {
        throw new ValidationError("Sign-in session expired. Please try Keycloak again.");
    }
    const tokenSet = await client.callback(keycloakRedirectUri(), params, {
        state,
        code_verifier: codeVerifier
    });
    const claims = tokenSet.claims();
    const sub = typeof claims.sub === "string" ? claims.sub : "";
    if (!sub) {
        throw new ValidationError("Keycloak token is missing subject (sub).");
    }
    const email = pickEmail({
        email: claims.email,
        preferred_username: claims.preferred_username
    });
    if (!email) {
        throw new ValidationError("Keycloak did not provide an email. Ensure scope includes email and the user has an email in Keycloak.");
    }
    const fullName = pickFullName({
        name: claims.name,
        preferred_username: claims.preferred_username
    }, email);
    const keycloakRole = roleFromAccessToken(tokenSet.access_token);
    const user = await upsertUserFromKeycloak({ sub, email, fullName, keycloakRole });
    const sessionToken = signToken({
        userId: user.id,
        email: user.email,
        role: user.role as UserRole
    });
    let redirectPath = "/dashboard";
    if (input.cookies.nextPath) {
        try {
            const decoded = decodeURIComponent(input.cookies.nextPath);
            if (decoded.startsWith("/")) {
                redirectPath = decoded;
            }
        }
        catch {
        }
    }
    return {
        sessionToken,
        user: {
            id: user.id,
            email: user.email,
            fullName: user.fullName,
            role: user.role as UserRole
        },
        redirectPath,
        clearOAuthCookies: buildExpiredKeycloakOAuthCookies()
    };
}
export function readKeycloakOAuthFromRequestCookies(get: (name: string) => string | undefined): {
    state: string | undefined;
    codeVerifier: string | undefined;
    nextPath: string | undefined;
} {
    return {
        state: get(KC_STATE_COOKIE),
        codeVerifier: get(KC_VERIFIER_COOKIE),
        nextPath: get(KC_NEXT_COOKIE)
    };
}
