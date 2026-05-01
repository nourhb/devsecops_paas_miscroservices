/**
 * Set a new password for an existing user (local Postgres / same DATABASE_URL as Next.js).
 * Also marks the email as verified so login works immediately.
 *
 * Usage (from paas/frontend):
 *   npm run auth:reset-password -- you@example.com "NewSecurePass123!"
 *
 * Do not use in production clusters without strict access control.
 */
const bcrypt = require("bcryptjs");
const { PrismaClient } = require("@prisma/client");

const ROUNDS = 12;

async function main() {
    const email = process.argv[2]?.trim().toLowerCase();
    const newPassword = process.argv[3] ?? "";
    if (!email || newPassword.length < 8) {
        console.error("Usage: npm run auth:reset-password -- <email> <newPassword>");
        console.error("Password must be at least 8 characters (same rule as the app).");
        process.exit(1);
    }
    const prisma = new PrismaClient();
    try {
        const user = await prisma.user.findUnique({ where: { email } });
        if (!user) {
            console.error(`No user with email "${email}".`);
            process.exit(1);
        }
        const passwordHash = await bcrypt.hash(newPassword, ROUNDS);
        await prisma.user.update({
            where: { id: user.id },
            data: {
                passwordHash,
                emailVerifiedAt: user.emailVerifiedAt ?? new Date()
            }
        });
        console.log(`Password updated for ${email}. You can sign in now.`);
    }
    finally {
        await prisma.$disconnect();
    }
}

main().catch((e) => {
    console.error(e);
    process.exit(1);
});
