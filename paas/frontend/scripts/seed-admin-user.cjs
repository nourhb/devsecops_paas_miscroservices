const bcrypt = require("bcryptjs");
const { PrismaClient } = require("@prisma/client");
const ROUNDS = 12;
const DEFAULT_EMAIL = "admin@paas.local";
const DEFAULT_PASSWORD = "123456789";
const DEFAULT_FULL_NAME = "Platform Admin";
async function main() {
    const email = (process.argv[2] || process.env.SEED_ADMIN_EMAIL || DEFAULT_EMAIL).trim().toLowerCase();
    const password = process.argv[3] || process.env.SEED_ADMIN_PASSWORD || DEFAULT_PASSWORD;
    const fullName = (process.argv[4] || process.env.SEED_ADMIN_FULL_NAME || DEFAULT_FULL_NAME).trim();
    if (!email.includes("@")) {
        console.error("Invalid email.");
        process.exit(1);
    }
    if (password.length < 8) {
        console.error("Password must be at least 8 characters (same rule as the app).");
        process.exit(1);
    }
    const prisma = new PrismaClient();
    try {
        const passwordHash = await bcrypt.hash(password, ROUNDS);
        const now = new Date();
        const user = await prisma.user.upsert({
            where: { email },
            create: {
                email,
                fullName,
                passwordHash,
                role: "ADMIN",
                emailVerifiedAt: now
            },
            update: {
                fullName,
                passwordHash,
                role: "ADMIN",
                emailVerifiedAt: now
            }
        });
        console.log("OK — admin user ready for login");
        console.log(`  email:    ${user.email}`);
        console.log(`  role:     ${user.role}`);
        console.log(`  id:       ${user.id}`);
        console.log(`  verified: ${user.emailVerifiedAt?.toISOString() ?? "no"}`);
        console.log("  password: (as provided — not printed)");
    }
    finally {
        await prisma.$disconnect();
    }
}
main().catch((e) => {
    console.error(e);
    process.exit(1);
});
