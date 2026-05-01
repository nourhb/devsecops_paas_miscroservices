import crypto from "node:crypto";
import bcrypt from "bcryptjs";
import { Prisma, Role } from "@prisma/client";
import { z } from "zod";
import { env } from "@/server/config/env";
import { prisma } from "@/server/db/prisma";
import { ApiError, UnauthorizedError, ValidationError } from "@/server/http/errors";
import { signToken } from "@/server/security/jwt";
import { createRawAuthToken, hashAuthToken } from "@/server/auth/auth-tokens";
import { getAppBaseUrl, sendAuthMail } from "@/server/auth/auth-mailer";
import type { AuthResponse, AuthStatusResponse, UserRole } from "@/types";
const EMAIL_VERIFICATION_TTL_MS = 1000 * 60 * 60 * 24;
const PASSWORD_RESET_TTL_MS = 1000 * 60 * 60;
type AuthTokenLookupRow = {
    id: string;
    userId: string;
    expiresAt: Date;
    email: string;
    fullName: string;
    role: Role;
};
type AuthUserLookupRow = {
    id: string;
    email: string;
    fullName: string;
    passwordHash: string;
    role: Role;
    emailVerifiedAt: Date | null;
};
function zodErrorMessage(error: z.ZodError): string {
    const flat = error.flatten();
    const root = flat.formErrors.filter(Boolean).join("; ");
    const fieldParts = Object.entries(flat.fieldErrors)
        .flatMap(([key, msgs]) => (msgs?.length ? msgs.map((m) => `${key}: ${m}`) : []))
        .join("; ");
    return [root, fieldParts].filter(Boolean).join(" — ") || "Invalid request";
}
const registerSchema = z.object({
    fullName: z.string().trim().min(2).max(120),
    email: z.string().trim().email(),
    password: z.string().min(8).max(100)
});
const loginSchema = z.object({
    email: z.string().trim().email(),
    password: z.string().min(8).max(100)
});
const forgotPasswordSchema = z.object({
    email: z.string().trim().email()
});
const verifyEmailSchema = z.object({
    token: z.string().trim().min(20)
});
const resendVerificationSchema = z.object({
    email: z.string().trim().email()
});
const resetPasswordSchema = z.object({
    token: z.string().trim().min(20),
    password: z.string().min(8).max(100)
});
function buildVerificationUrl(token: string) {
    return `${getAppBaseUrl()}/verify-email?token=${encodeURIComponent(token)}`;
}
function buildResetPasswordUrl(token: string) {
    return `${getAppBaseUrl()}/reset-password?token=${encodeURIComponent(token)}`;
}
function toAuthUser(user: {
    id: string;
    email: string;
    fullName: string;
    role: Role;
}) {
    return {
        id: user.id,
        email: user.email,
        fullName: user.fullName,
        role: user.role as UserRole
    };
}
async function createEmailVerificationToken(userId: string) {
    await prisma.$executeRaw(Prisma.sql `DELETE FROM "EmailVerificationToken" WHERE "userId" = ${userId}`);
    const rawToken = createRawAuthToken();
    await prisma.$executeRaw(Prisma.sql `
        INSERT INTO "EmailVerificationToken" ("id", "userId", "tokenHash", "expiresAt", "createdAt")
        VALUES (${crypto.randomUUID()}, ${userId}, ${hashAuthToken(rawToken)}, ${new Date(Date.now() + EMAIL_VERIFICATION_TTL_MS)}, ${new Date()})
    `);
    return rawToken;
}
async function createPasswordResetToken(userId: string) {
    await prisma.$executeRaw(Prisma.sql `DELETE FROM "PasswordResetToken" WHERE "userId" = ${userId}`);
    const rawToken = createRawAuthToken();
    await prisma.$executeRaw(Prisma.sql `
        INSERT INTO "PasswordResetToken" ("id", "userId", "tokenHash", "expiresAt", "createdAt")
        VALUES (${crypto.randomUUID()}, ${userId}, ${hashAuthToken(rawToken)}, ${new Date(Date.now() + PASSWORD_RESET_TTL_MS)}, ${new Date()})
    `);
    return rawToken;
}
async function getEmailVerificationToken(token: string) {
    const rows = await prisma.$queryRaw<AuthTokenLookupRow[]>(Prisma.sql `
        SELECT evt."id", evt."userId", evt."expiresAt", u."email", u."fullName", u."role"
        FROM "EmailVerificationToken" evt
        INNER JOIN "User" u ON u."id" = evt."userId"
        WHERE evt."tokenHash" = ${hashAuthToken(token)}
        LIMIT 1
    `);
    return rows[0] || null;
}
async function getPasswordResetToken(token: string) {
    const rows = await prisma.$queryRaw<AuthTokenLookupRow[]>(Prisma.sql `
        SELECT prt."id", prt."userId", prt."expiresAt", u."email", u."fullName", u."role"
        FROM "PasswordResetToken" prt
        INNER JOIN "User" u ON u."id" = prt."userId"
        WHERE prt."tokenHash" = ${hashAuthToken(token)}
        LIMIT 1
    `);
    return rows[0] || null;
}
async function getAuthUserByEmail(email: string) {
    const rows = await prisma.$queryRaw<AuthUserLookupRow[]>(Prisma.sql `
        SELECT "id", "email", "fullName", "passwordHash", "role", "emailVerifiedAt"
        FROM "User"
        WHERE "email" = ${email}
        LIMIT 1
    `);
    return rows[0] || null;
}
export async function getAuthUserById(userId: string) {
    const rows = await prisma.$queryRaw<AuthUserLookupRow[]>(Prisma.sql `
        SELECT "id", "email", "fullName", "passwordHash", "role", "emailVerifiedAt"
        FROM "User"
        WHERE "id" = ${userId}
        LIMIT 1
    `);
    return rows[0] || null;
}
async function sendVerificationEmail(user: {
    id: string;
    email: string;
    fullName: string;
}) {
    const token = await createEmailVerificationToken(user.id);
    const verificationUrl = buildVerificationUrl(token);
    const delivery = await sendAuthMail({
        to: user.email,
        subject: "Verify your DevSecOps PaaS account",
        text: `Hello ${user.fullName}, verify your account by opening this link: ${verificationUrl}`,
        html: `<p>Hello ${user.fullName},</p><p>Verify your DevSecOps PaaS account by clicking the link below:</p><p><a href="${verificationUrl}">${verificationUrl}</a></p>`
    });
    return delivery.mode;
}
async function sendPasswordResetEmail(user: {
    id: string;
    email: string;
    fullName: string;
}) {
    const token = await createPasswordResetToken(user.id);
    const resetUrl = buildResetPasswordUrl(token);
    const delivery = await sendAuthMail({
        to: user.email,
        subject: "Reset your DevSecOps PaaS password",
        text: `Hello ${user.fullName}, reset your password by opening this link: ${resetUrl}`,
        html: `<p>Hello ${user.fullName},</p><p>Reset your password by clicking the link below:</p><p><a href="${resetUrl}">${resetUrl}</a></p>`
    });
    return delivery.mode;
}
export async function registerUser(payload: unknown): Promise<AuthStatusResponse> {
    const parsed = registerSchema.safeParse(payload);
    if (!parsed.success) {
        throw new ValidationError(zodErrorMessage(parsed.error));
    }
    const email = parsed.data.email.toLowerCase();
    const existing = await getAuthUserByEmail(email);
    if (existing) {
        throw new ValidationError("Email is already registered");
    }
    const hashedPassword = await bcrypt.hash(parsed.data.password, 12);
    let user;
    try {
        user = await prisma.user.create({
            data: {
                fullName: parsed.data.fullName,
                email,
                passwordHash: hashedPassword,
                role: Role.DEVELOPER,
                emailVerifiedAt: new Date()
            }
        });
    }
    catch (e) {
        if (e instanceof Prisma.PrismaClientKnownRequestError && e.code === "P2002") {
            throw new ValidationError("Email is already registered");
        }
        throw e;
    }
    return {
        success: true,
        email: user.email,
        message: "Account created. Signing you in...",
        requiresVerification: false,
        mailDelivery: "none"
    };
}
export async function loginUser(payload: unknown): Promise<AuthResponse> {
    const parsed = loginSchema.safeParse(payload);
    if (!parsed.success) {
        throw new ValidationError(zodErrorMessage(parsed.error));
    }
    const email = parsed.data.email.toLowerCase();
    const user = await getAuthUserByEmail(email);
    if (!user) {
        throw new UnauthorizedError("Invalid credentials");
    }
    const allowUnverifiedDev = env.NODE_ENV === "development" && env.AUTH_ALLOW_UNVERIFIED_LOGIN === "true";
    if (!user.emailVerifiedAt && !allowUnverifiedDev) {
        throw new ApiError(403, "Please verify your email before signing in.", {
            data: {
                code: "EMAIL_NOT_VERIFIED",
                email: user.email
            }
        });
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
        user: toAuthUser(user)
    };
}
export async function verifyEmailToken(payload: unknown): Promise<AuthStatusResponse> {
    const parsed = verifyEmailSchema.safeParse(payload);
    if (!parsed.success) {
        throw new ValidationError(zodErrorMessage(parsed.error));
    }
    const tokenRecord = await getEmailVerificationToken(parsed.data.token);
    if (!tokenRecord || tokenRecord.expiresAt.getTime() < Date.now()) {
        if (tokenRecord) {
            await prisma.$executeRaw(Prisma.sql `DELETE FROM "EmailVerificationToken" WHERE "id" = ${tokenRecord.id}`);
        }
        throw new ValidationError("This verification link is invalid or expired.");
    }
    await prisma.$transaction([
        prisma.$executeRaw(Prisma.sql `
            UPDATE "User"
            SET "emailVerifiedAt" = ${new Date()}
            WHERE "id" = ${tokenRecord.userId}
        `),
        prisma.$executeRaw(Prisma.sql `DELETE FROM "EmailVerificationToken" WHERE "userId" = ${tokenRecord.userId}`)
    ]);
    return {
        success: true,
        email: tokenRecord.email,
        message: "Email verified successfully. You can now sign in.",
        requiresVerification: false,
        mailDelivery: "none"
    };
}
export async function resendVerificationEmail(payload: unknown): Promise<AuthStatusResponse> {
    const parsed = resendVerificationSchema.safeParse(payload);
    if (!parsed.success) {
        throw new ValidationError(zodErrorMessage(parsed.error));
    }
    const user = await getAuthUserByEmail(parsed.data.email.toLowerCase());
    if (!user) {
        return {
            success: true,
            email: parsed.data.email.toLowerCase(),
            message: "If that email exists, a verification message has been sent.",
            requiresVerification: true,
            mailDelivery: "none"
        };
    }
    if (user.emailVerifiedAt) {
        return {
            success: true,
            email: user.email,
            message: "This account is already verified. You can sign in now.",
            requiresVerification: false,
            mailDelivery: "none"
        };
    }
    const mailDelivery = await sendVerificationEmail(user);
    return {
        success: true,
        email: user.email,
        message: "Verification email sent.",
        requiresVerification: true,
        mailDelivery
    };
}
export async function requestPasswordReset(payload: unknown): Promise<AuthStatusResponse> {
    const parsed = forgotPasswordSchema.safeParse(payload);
    if (!parsed.success) {
        throw new ValidationError(zodErrorMessage(parsed.error));
    }
    const email = parsed.data.email.toLowerCase();
    const user = await getAuthUserByEmail(email);
    if (!user) {
        return {
            success: true,
            email,
            message: "If that email exists, a password reset link has been sent.",
            requiresVerification: false,
            mailDelivery: "none"
        };
    }
    const mailDelivery = await sendPasswordResetEmail(user);
    return {
        success: true,
        email: user.email,
        message: "If that email exists, a password reset link has been sent.",
        requiresVerification: false,
        mailDelivery
    };
}
export async function resetPassword(payload: unknown): Promise<AuthStatusResponse> {
    const parsed = resetPasswordSchema.safeParse(payload);
    if (!parsed.success) {
        throw new ValidationError(zodErrorMessage(parsed.error));
    }
    const tokenRecord = await getPasswordResetToken(parsed.data.token);
    if (!tokenRecord || tokenRecord.expiresAt.getTime() < Date.now()) {
        if (tokenRecord) {
            await prisma.$executeRaw(Prisma.sql `DELETE FROM "PasswordResetToken" WHERE "id" = ${tokenRecord.id}`);
        }
        throw new ValidationError("This password reset link is invalid or expired.");
    }
    const passwordHash = await bcrypt.hash(parsed.data.password, 12);
    await prisma.$transaction([
        prisma.user.update({
            where: { id: tokenRecord.userId },
            data: { passwordHash }
        }),
        prisma.$executeRaw(Prisma.sql `DELETE FROM "PasswordResetToken" WHERE "userId" = ${tokenRecord.userId}`)
    ]);
    return {
        success: true,
        email: tokenRecord.email,
        message: "Password updated successfully. You can now sign in.",
        requiresVerification: false,
        mailDelivery: "none"
    };
}
