import { NextRequest } from "next/server";
import * as jwt from "jsonwebtoken";
import { getAuthUserById } from "@/server/auth/auth-service";
import { verifyToken } from "@/server/security/jwt";
import { getSessionCookieName } from "@/server/auth/session-cookie";
import { isTransientDbError, withPrismaRetry } from "@/server/db/prisma-retry";
import { ForbiddenError, ServiceUnavailableError, UnauthorizedError } from "@/server/http/errors";
import type { UserRole } from "@/types";
export interface AuthContext {
    userId: string;
    email: string;
    role: UserRole;
}
function resolveToken(request: NextRequest) {
    const authHeader = request.headers.get("authorization");
    if (authHeader?.startsWith("Bearer ")) {
        return authHeader.replace("Bearer ", "").trim();
    }
    return request.cookies.get(getSessionCookieName())?.value?.trim() || "";
}
function isJwtAuthError(error: unknown): boolean {
    return error instanceof jwt.TokenExpiredError
        || error instanceof jwt.JsonWebTokenError
        || error instanceof jwt.NotBeforeError;
}
export async function requireAuth(request: NextRequest, allowedRoles?: UserRole[]): Promise<AuthContext> {
    const token = resolveToken(request);
    if (!token) {
        throw new UnauthorizedError("Authentication is required");
    }
    try {
        const payload = verifyToken(token);
        const user = await withPrismaRetry(() => getAuthUserById(payload.userId));
        if (!user) {
            throw new UnauthorizedError("Your session is no longer valid (account missing\u2014often after a database reset). Sign out and sign in again.");
        }
        const role = user.role as UserRole;
        if (allowedRoles && !allowedRoles.includes(role)) {
            throw new ForbiddenError("Insufficient role privileges");
        }
        return {
            userId: user.id,
            email: user.email,
            role
        };
    }
    catch (error) {
        if (error instanceof ForbiddenError) {
            throw error;
        }
        if (error instanceof UnauthorizedError) {
            throw error;
        }
        if (isTransientDbError(error)) {
            throw new ServiceUnavailableError("Database temporarily unavailable. Wait a few seconds and refresh — your session is still valid.");
        }
        if (isJwtAuthError(error)) {
            throw new UnauthorizedError("Invalid or expired token");
        }
        throw error;
    }
}
