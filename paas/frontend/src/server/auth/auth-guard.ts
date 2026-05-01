import { NextRequest } from "next/server";
import { verifyToken } from "@/server/security/jwt";
import { getSessionCookieName } from "@/server/auth/session-cookie";
import { ForbiddenError, UnauthorizedError } from "@/server/http/errors";
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
export function requireAuth(request: NextRequest, allowedRoles?: UserRole[]): AuthContext {
    const token = resolveToken(request);
    if (!token) {
        throw new UnauthorizedError("Authentication is required");
    }
    try {
        const payload = verifyToken(token);
        if (allowedRoles && !allowedRoles.includes(payload.role)) {
            throw new ForbiddenError("Insufficient role privileges");
        }
        return {
            userId: payload.userId,
            email: payload.email,
            role: payload.role
        };
    }
    catch (error) {
        if (error instanceof ForbiddenError) {
            throw error;
        }
        throw new UnauthorizedError("Invalid or expired token");
    }
}
