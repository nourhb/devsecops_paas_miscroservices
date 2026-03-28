import bcrypt from "bcryptjs";
import { Role } from "@prisma/client";
import { z } from "zod";
import { prisma } from "@/server/db/prisma";
import { ValidationError, UnauthorizedError } from "@/server/http/errors";
import { signToken } from "@/server/security/jwt";
import type { AuthResponse, UserRole } from "@/types";

const registerSchema = z.object({
  fullName: z.string().min(2).max(120),
  email: z.string().email(),
  password: z.string().min(8).max(100),
  role: z.enum(["ADMIN", "DEVELOPER"]).default("DEVELOPER")
});

const loginSchema = z.object({
  email: z.string().email(),
  password: z.string().min(8).max(100)
});

export async function registerUser(payload: unknown): Promise<AuthResponse> {
  const parsed = registerSchema.safeParse(payload);
  if (!parsed.success) {
    throw new ValidationError(parsed.error.flatten().formErrors.join(", ") || "Invalid registration payload");
  }

  const email = parsed.data.email.toLowerCase();
  const existing = await prisma.user.findUnique({ where: { email } });
  if (existing) {
    throw new ValidationError("Email is already registered");
  }

  const hashedPassword = await bcrypt.hash(parsed.data.password, 12);
  const user = await prisma.user.create({
    data: {
      fullName: parsed.data.fullName,
      email,
      passwordHash: hashedPassword,
      role: parsed.data.role as Role
    }
  });

  const token = signToken({
    userId: user.id,
    email: user.email,
    role: user.role as UserRole
  });

  return {
    token,
    user: {
      id: user.id,
      email: user.email,
      fullName: user.fullName,
      role: user.role as UserRole
    }
  };
}

export async function loginUser(payload: unknown): Promise<AuthResponse> {
  const parsed = loginSchema.safeParse(payload);
  if (!parsed.success) {
    throw new ValidationError("Invalid login payload");
  }

  const email = parsed.data.email.toLowerCase();
  const user = await prisma.user.findUnique({ where: { email } });

  if (!user) {
    throw new UnauthorizedError("Invalid credentials");
  }

  const isValidPassword = await bcrypt.compare(parsed.data.password, user.passwordHash);
  if (!isValidPassword) {
    throw new UnauthorizedError("Invalid credentials");
  }

  const token = signToken({
    userId: user.id,
    email: user.email,
    role: user.role as UserRole
  });

  return {
    token,
    user: {
      id: user.id,
      email: user.email,
      fullName: user.fullName,
      role: user.role as UserRole
    }
  };
}
