const { PrismaClient } = require("@prisma/client");
async function main() {
    const raw = process.argv[2];
    const email = raw ? String(raw).trim().toLowerCase() : "";
    if (!email) {
        console.error("Usage: node scripts/verify-user-email.cjs <email>");
        process.exit(1);
    }
    const prisma = new PrismaClient();
    try {
        const r = await prisma.user.updateMany({
            where: { email },
            data: { emailVerifiedAt: new Date() }
        });
        if (r.count === 0) {
            console.error(`No user found with email "${email}". Register first or check DATABASE_URL.`);
            process.exit(1);
        }
        console.log(`Email verified for ${email}. You can sign in now.`);
    }
    finally {
        await prisma.$disconnect();
    }
}
main().catch((e) => {
    console.error(e);
    process.exit(1);
});
