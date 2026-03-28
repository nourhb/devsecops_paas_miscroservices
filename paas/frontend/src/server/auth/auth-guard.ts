import { NextRequest } from "next/server";
import { verifyToken } from "@/server/security/jwt";
import { ForbiddenError, UnauthorizedError } from "@/server/http/errors";
import type { UserRole } from "@/types";

export interface AuthContext {
  userId: string;
  email: string;
  role: UserRole;
}

export function requireAuth(request: NextRequest, allowedRoles?: UserRole[]): AuthContext {
  const authHeader = request.headers.get("authorization");
  if (!authHeader || !authHeader.startsWith("Bearer ")) {
    throw new UnauthorizedError("Missing bearer token");
  }

  const token = authHeader.replace("Bearer ", "").trim();

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
  } catch (error) {
    if (error instanceof ForbiddenError) {
      throw error;
    }

    throw new UnauthorizedError("Invalid or expired token");
  }
}
